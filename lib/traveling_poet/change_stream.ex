defmodule TravelingPoet.ChangeStream do
  @moduledoc """
  Publishes every change to the main database, in batches, to admin-registered
  webhook endpoints — so external operator agents (SRE, marketing, support)
  can keep a live mirror of the domain model.

  ## How it works

  `Capture` diffs a content fingerprint per row on a timer and writes
  insert/update/delete events to an outbox (SQLite has no change feed, and
  Ecto write callbacks cannot be wrapped). `Delivery` sends each endpoint the
  events past its cursor, when the batch is full or old enough, signs them,
  and tracks health with exponential backoff. `Backfill` sends the whole
  database to a new endpoint. `Worker` is the timer. All of it is idle while
  no endpoint exists (`enabled?/0`).

  ## Consumer contract

  POST, `content-type: application/json`, body:

      {"type": "changes" | "backfill" | "ping",
       "batch_id": "b_…", "sent_at": "2026-09-01T10:00:00Z",
       "source": "traveling-poet",
       "events": [
         {"id": 1234, "entity": "places", "action": "insert",
          "occurred_at": "2026-09-01T09:59:30Z",
          "record": {"id": 88, "poet_id": 3, "name": "…", …}},
         {"id": 1235, "entity": "users", "action": "delete",
          "occurred_at": "…", "record": {"id": 7}}]}

  Headers: `authorization: Bearer <auth_token>` (the token given at
  registration), `x-poet-signature: t=<unix seconds>,v1=<hex>` where `v1` is
  HMAC-SHA256 with the endpoint's signing secret over `"<t>.<raw body>"`
  (the Stripe recipe — verify with a constant-time compare and reject stale
  `t`), and `x-poet-batch-id`.

  Answer any 2xx to acknowledge; the body is ignored. Anything else, or a
  timeout, means the SAME batch is sent again later, so delivery is
  at-least-once: dedupe `changes` on event `id`. Backfill events carry
  `"id": null` and `"action": "upsert"`; apply them by `(entity, record.id)`.
  Naive timestamps (`inserted_at`, `updated_at`) are UTC. Delete records
  carry only the id. Fields that never leave the app are listed by
  `redacted_fields/0`; secrets always, plus user email, OAuth ids, Telegram
  ids, and chat message content. The `geocode_cache` table is not streamed.

  ## Operations

  Register endpoints at `/admin/change-stream`. The first registration seeds
  fingerprints silently; run a backfill next. Console: `Worker.check_now/0`,
  `Backfill.run/1`.

  Secrets are plaintext columns, like every other credential in this DB.
  """

  import Ecto.Query
  require Logger

  alias TravelingPoet.ChangeStream.{
    Backfill,
    Capture,
    Delivery,
    Endpoint,
    Event,
    Fingerprint,
    Registry,
    Serializer
  }

  alias TravelingPoet.Repo

  @enabled_key {__MODULE__, :enabled?}

  # -- endpoints --

  def list_endpoints, do: Repo.all(from(e in Endpoint, order_by: e.id))
  def get_endpoint!(id), do: Repo.get!(Endpoint, id)
  def get_endpoint(id), do: Repo.get(Endpoint, id)

  @doc """
  Registers a receiver. Generates the signing secret (returned on the struct;
  the UI shows it once). The first endpoint also seeds fingerprints, so the
  stream starts from "now" and the backfill — not a storm of inserts — is how
  the receiver learns the past.
  """
  def create_endpoint(attrs) do
    first? = not Repo.exists?(Endpoint)

    result =
      %Endpoint{}
      |> Endpoint.changeset(attrs)
      |> Ecto.Changeset.put_change(:signing_secret, generate_secret())
      |> Repo.insert()

    with {:ok, endpoint} <- result do
      if first?, do: Capture.seed()
      refresh_enabled!()
      {:ok, endpoint}
    end
  end

  @doc "Removes a receiver; when it was the last, clears the outbox and fingerprints."
  def delete_endpoint(%Endpoint{} = endpoint) do
    {:ok, _} = Repo.delete(endpoint)
    unless Repo.exists?(Endpoint), do: reset()
    refresh_enabled!()
    :ok
  end

  def pause(%Endpoint{} = endpoint), do: set_status(endpoint, "paused")

  @doc "Back to active with a clean slate: failures and backoff cleared."
  def resume(%Endpoint{} = endpoint) do
    endpoint
    |> Ecto.Changeset.change(status: "active", consecutive_failures: 0, next_attempt_at: nil)
    |> Repo.update()
  end

  @doc "Clears the backoff gate and sends whatever is pending, regardless of size or age."
  def retry_now(%Endpoint{} = endpoint, now \\ DateTime.utc_now()) do
    {:ok, endpoint} =
      endpoint |> Ecto.Changeset.change(next_attempt_at: nil) |> Repo.update()

    Delivery.deliver(endpoint, now, force: true)
  end

  def ping(%Endpoint{} = endpoint), do: Delivery.ping(endpoint)

  @doc "Kicks off a backfill in the background. `{:error, :already_running}` if one is."
  def start_backfill(%Endpoint{backfill_status: "running"}), do: {:error, :already_running}

  def start_backfill(%Endpoint{} = endpoint) do
    Task.start(fn -> Backfill.run(endpoint.id) end)
    :ok
  end

  # -- enabled flag --

  @doc "True while at least one endpoint is registered. Cheap: persistent_term."
  def enabled?, do: :persistent_term.get(@enabled_key, false)

  def refresh_enabled! do
    enabled = Repo.exists?(Endpoint)
    :persistent_term.put(@enabled_key, enabled)
    enabled
  end

  # -- the pass --

  @doc "Capture → deliver → prune. Each stage rescued so one cannot stop the next."
  def run_once(now \\ DateTime.utc_now()) do
    %{
      capture: stage("capture", fn -> Capture.tick(now) end),
      delivery: stage("delivery", fn -> Delivery.deliver_pending(now) end),
      prune: stage("prune", fn -> Delivery.prune(now) end)
    }
  end

  defp stage(name, fun) do
    fun.()
  rescue
    e ->
      Logger.error("ChangeStream: #{name} stage crashed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc "Empties the outbox and the fingerprints."
  def reset do
    Repo.delete_all(Event)
    Capture.reset()
    :ok
  end

  # -- status helpers for the UI --

  def latest_event_id, do: Repo.one(from(ev in Event, select: max(ev.id))) || 0
  def oldest_event_id, do: Repo.one(from(ev in Event, select: min(ev.id)))

  @doc "Events this endpoint has not acknowledged yet."
  def lag(%Endpoint{cursor_event_id: cursor}), do: max(latest_event_id() - cursor, 0)

  @doc "True when events were pruned before this endpoint saw them — it needs a backfill."
  def gap?(%Endpoint{cursor_event_id: cursor}) do
    case oldest_event_id() do
      nil -> false
      oldest -> oldest > cursor + 1
    end
  end

  def redacted_fields do
    Map.new(Registry.streamed(), fn {entity, schema} ->
      {entity, Serializer.redacted_fields(entity, schema)}
    end)
  end

  # -- config --

  def poll_seconds, do: Application.get_env(:traveling_poet, :change_stream_poll_seconds, 0)
  def batch_size, do: Application.get_env(:traveling_poet, :change_stream_batch_size, 100)

  def max_wait_seconds,
    do: Application.get_env(:traveling_poet, :change_stream_max_batch_wait_seconds, 60)

  def failure_threshold,
    do: Application.get_env(:traveling_poet, :change_stream_failure_threshold, 5)

  @doc "Extra Req options; the test config routes through `Req.Test`."
  def req_options, do: Application.get_env(:traveling_poet, :change_stream_req_options, [])

  # -- internals --

  defp set_status(endpoint, status) do
    endpoint |> Ecto.Changeset.change(status: status) |> Repo.update()
  end

  defp generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc false
  def fingerprint_count, do: Repo.aggregate(Fingerprint, :count)
end
