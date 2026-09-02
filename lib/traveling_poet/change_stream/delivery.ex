defmodule TravelingPoet.ChangeStream.Delivery do
  @moduledoc """
  Sends outbox batches to endpoints and keeps each endpoint's health honest.

  Per endpoint: read events past its cursor, up to the batch size. Send when
  the batch is full OR its oldest event has waited longer than the max wait —
  size alone would leave this low-volume app's events sitting for days. A 2xx
  advances the cursor; anything else counts a failure and backs off
  exponentially (30s doubling, capped at an hour). After the failure threshold
  the endpoint is flagged `failing` and admins are paged ONCE, on the
  transition; it keeps retrying at the cap, and the first success pages a
  recovery. Paused endpoints are skipped, cursor untouched.

  Delivery is at-least-once: a batch that was received but whose 2xx was lost
  is sent again. Consumers dedupe on event id.

  Retries are ours, not Req's (`retry: false`): the endpoint row is the retry
  state, so it survives a deploy and is visible in the admin UI.
  """

  import Ecto.Query
  require Logger

  alias TravelingPoet.ChangeStream
  alias TravelingPoet.ChangeStream.{Endpoint, Event, Registry, Serializer}
  alias TravelingPoet.Payments.Stripe
  alias TravelingPoet.{Alerts, Repo}

  @receive_timeout 15_000
  @backoff_base_s 30
  @backoff_cap_s 3_600
  @retention_days 7
  @error_limit 500

  @doc "Delivers to every endpoint that is due. Returns `{endpoint_id, result}` pairs."
  def deliver_pending(now \\ DateTime.utc_now()) do
    Endpoint
    |> where([e], e.status in ["active", "failing"])
    |> where([e], is_nil(e.next_attempt_at) or e.next_attempt_at <= ^now)
    |> Repo.all()
    |> Enum.map(fn endpoint -> {endpoint.id, deliver(endpoint, now)} end)
  end

  @doc """
  One delivery attempt for one endpoint. `:skipped` when there is nothing
  due; `force: true` sends whatever is pending regardless of size and age
  (the admin's "retry now").
  """
  def deliver(endpoint, now, opts \\ [])

  def deliver(%Endpoint{status: "paused"}, _now, _opts), do: :skipped

  def deliver(%Endpoint{} = endpoint, now, opts) do
    force? = Keyword.get(opts, :force, false)
    events = pending(endpoint, ChangeStream.batch_size())

    cond do
      events == [] ->
        :skipped

      not force? and not due?(events, now) ->
        :skipped

      true ->
        case post(endpoint, envelope("changes", Enum.map(events, &wire_event/1), now)) do
          {:ok, status} ->
            record_success(endpoint, List.last(events).id, status, now)
            :ok

          {:error, reason} ->
            record_failure(endpoint, reason, now)
            {:error, reason}
        end
    end
  end

  @doc "An empty batch, synchronous, no counters touched. For the admin's Ping."
  def ping(%Endpoint{} = endpoint, now \\ DateTime.utc_now()) do
    post(endpoint, envelope("ping", [], now))
  end

  @doc """
  Signs and POSTs one envelope. Shared by the live stream and the backfill.
  Returns `{:ok, status}` on any 2xx; `{:error, {:http, status, body}}` or
  `{:error, transport_reason}` otherwise.
  """
  def post(%Endpoint{} = endpoint, envelope) when is_map(envelope) do
    # Sign the exact bytes we send: encode once, pass as `body:`, never `json:`.
    body = Jason.encode!(envelope)
    t = System.os_time(:second)
    signature = "t=#{t},v1=#{Stripe.sign(endpoint.signing_secret, "#{t}.#{body}")}"

    request =
      [
        body: body,
        headers: [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{endpoint.auth_token}"},
          {"x-poet-signature", signature},
          {"x-poet-batch-id", envelope["batch_id"]}
        ],
        receive_timeout: @receive_timeout,
        retry: false
      ] ++ ChangeStream.req_options()

    case Req.post(endpoint.url, request) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, status}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning(
          "ChangeStream: #{endpoint.url} answered #{status}: #{inspect(body, limit: 200)}"
        )

        {:error, {:http, status, body}}

      {:error, reason} ->
        Logger.warning("ChangeStream: #{endpoint.url} unreachable: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "The wire envelope. `events` are already wire-shaped maps."
  def envelope(type, events, now \\ DateTime.utc_now()) do
    %{
      "type" => type,
      "batch_id" => "b_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "sent_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "source" => "traveling-poet",
      "events" => events
    }
  end

  @doc "A backfill event: no outbox id, `upsert`, occurred_at = send time."
  def backfill_event(entity, struct, now) do
    %{
      "id" => nil,
      "entity" => entity,
      "action" => "upsert",
      "occurred_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "record" => Serializer.encode(entity, struct)
    }
  end

  @doc "Exponential backoff in seconds for the n-th consecutive failure."
  def backoff_seconds(n) when n >= 1 do
    min(@backoff_cap_s, @backoff_base_s * Integer.pow(2, n - 1))
  end

  @doc """
  Drops events every endpoint has acknowledged, and — regardless of
  acknowledgement — anything older than the retention window, so a paused
  endpoint cannot pin the outbox forever. An endpoint that falls behind the
  window shows a gap in the admin UI; the fix is a backfill.
  """
  def prune(now \\ DateTime.utc_now()) do
    safe = Repo.one(from(e in Endpoint, select: min(e.cursor_event_id))) || 0
    cutoff = DateTime.add(now, -@retention_days * 86_400, :second)

    {acked, _} = Repo.delete_all(from(ev in Event, where: ev.id <= ^safe))
    {expired, _} = Repo.delete_all(from(ev in Event, where: ev.occurred_at < ^cutoff))
    %{acked: acked, expired: expired}
  end

  def retention_days, do: @retention_days

  @doc "Events past the cursor, oldest first."
  def pending(%Endpoint{cursor_event_id: cursor}, limit) do
    Event
    |> where([ev], ev.id > ^cursor)
    |> order_by([ev], asc: ev.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp due?(events, now) do
    full? = length(events) >= ChangeStream.batch_size()
    oldest = hd(events).occurred_at
    aged? = DateTime.diff(now, oldest, :second) >= ChangeStream.max_wait_seconds()
    full? or aged?
  end

  defp wire_event(%Event{} = ev) do
    %{
      "id" => ev.id,
      "entity" => ev.entity,
      "action" => ev.action,
      "occurred_at" => DateTime.to_iso8601(ev.occurred_at),
      "record" => ev.payload
    }
  end

  defp record_success(endpoint, last_id, status, now) do
    now = DateTime.truncate(now, :second)

    # Monotonic: a concurrent "retry now" and a worker tick may both succeed
    # with overlapping batches; the cursor only ever moves forward.
    Repo.update_all(
      from(e in Endpoint, where: e.id == ^endpoint.id and e.cursor_event_id < ^last_id),
      set: [cursor_event_id: last_id]
    )

    Repo.update_all(from(e in Endpoint, where: e.id == ^endpoint.id),
      set: [
        consecutive_failures: 0,
        next_attempt_at: nil,
        last_success_at: now,
        last_status_code: status,
        last_error: nil,
        status: "active",
        updated_at: DateTime.to_naive(now)
      ]
    )

    if endpoint.status == "failing" do
      Logger.info("ChangeStream: #{endpoint.url} recovered")
      notify("✅ Traveling Poet: change-stream endpoint #{endpoint.url} recovered.")
    end

    :ok
  end

  defp record_failure(endpoint, reason, now) do
    now = DateTime.truncate(now, :second)
    n = endpoint.consecutive_failures + 1
    threshold = ChangeStream.failure_threshold()
    flip? = endpoint.status == "active" and n >= threshold
    status_code = with {:http, code, _} <- reason, do: code, else: (_ -> nil)
    error = reason |> inspect(limit: 100) |> String.slice(0, @error_limit)

    Repo.update_all(from(e in Endpoint, where: e.id == ^endpoint.id),
      set: [
        consecutive_failures: n,
        next_attempt_at: DateTime.add(now, backoff_seconds(n), :second),
        last_failure_at: now,
        last_status_code: status_code,
        last_error: error,
        status: if(flip?, do: "failing", else: endpoint.status),
        updated_at: DateTime.to_naive(now)
      ]
    )

    if flip? do
      Logger.error("ChangeStream: #{endpoint.url} flagged failing after #{n} failures: #{error}")

      notify(
        "⚠️ Traveling Poet: change-stream endpoint #{endpoint.url} is failing " <>
          "(#{n} consecutive failures, last: #{error}).\n\n" <>
          "Status: #{Alerts.admin_url("/admin/change-stream")}"
      )
    end

    :ok
  end

  # Alerting must never take delivery down with it.
  defp notify(text) do
    case Alerts.notify_admins(text) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("ChangeStream: could not alert admins: #{inspect(reason)}")
    end
  end

  @doc false
  def entities, do: Registry.entities()
end
