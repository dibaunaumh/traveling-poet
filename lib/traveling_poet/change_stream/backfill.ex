defmodule TravelingPoet.ChangeStream.Backfill do
  @moduledoc """
  Sends the whole current database to one endpoint, table by table in
  FK-parent-first order, as `"type": "backfill"` batches of `upsert` events.

  A plain module rather than something inside the admin LiveView, for the same
  reason as `Guide.Backfill`: production is a release, and this must be
  callable over rpc:

      bin/traveling_poet rpc 'TravelingPoet.ChangeStream.Backfill.run(1)'

  The endpoint row is the lock and the progress report: `backfill_status`
  flips to `running` with a conditional UPDATE (so two admins clicking at once
  start one run), `backfill_progress` is rewritten after every page, and the
  run ends in `done` or `failed` — including when it crashes, which is why
  everything is rescued.

  Overlap with the live stream is harmless: the consumer upserts by
  `(entity, id)`, and live events for the same rows just re-apply.
  """

  import Ecto.Query
  require Logger

  alias TravelingPoet.ChangeStream
  alias TravelingPoet.ChangeStream.{Delivery, Endpoint, Registry}
  alias TravelingPoet.Repo

  @max_attempts 5

  @doc "Row counts per entity — what a run would send. Cheap, no network."
  def plan do
    Enum.map(Registry.streamed(), fn {entity, schema} ->
      %{entity: entity, total: Repo.aggregate(schema, :count)}
    end)
  end

  @doc """
  Runs the backfill for `endpoint_id`. Options: `:batch_size` (default the
  stream's), `:sleep_ms` between retries (default from backoff; tests pass 0).
  Returns `{:ok, %{entities: [...], totals: %{sent: n}}}`, `{:error,
  :already_running}`, or `{:error, reason}` after a page exhausts its retries.
  """
  def run(endpoint_id, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case acquire(endpoint_id, now) do
      :ok ->
        try do
          do_run(Repo.get!(Endpoint, endpoint_id), now, opts)
        rescue
          e ->
            finish(endpoint_id, "failed", now, error: Exception.message(e))
            Logger.error("ChangeStream.Backfill: crashed: #{Exception.message(e)}")
            {:error, Exception.message(e)}
        end

      {:error, _} = err ->
        err
    end
  end

  defp do_run(endpoint, now, opts) do
    batch_size = Keyword.get(opts, :batch_size, ChangeStream.batch_size())

    result =
      Enum.reduce_while(Registry.streamed(), {:ok, []}, fn {entity, schema}, {:ok, done} ->
        total = Repo.aggregate(schema, :count)
        progress(endpoint.id, entity, 0, total, now)

        case send_entity(endpoint, entity, schema, total, batch_size, now, opts) do
          {:ok, sent} -> {:cont, {:ok, [%{entity: entity, sent: sent} | done]}}
          {:error, reason} -> {:halt, {:error, reason, Enum.reverse(done)}}
        end
      end)

    case result do
      {:ok, entities} ->
        entities = Enum.reverse(entities)
        sent = entities |> Enum.map(& &1.sent) |> Enum.sum()
        finish(endpoint.id, "done", now)
        Logger.info("ChangeStream.Backfill: sent #{sent} records to #{endpoint.url}")
        {:ok, %{entities: entities, totals: %{sent: sent}}}

      {:error, reason, _done} ->
        error = reason |> inspect(limit: 100) |> String.slice(0, 500)
        finish(endpoint.id, "failed", now, error: error)
        Logger.error("ChangeStream.Backfill: #{endpoint.url} failed: #{error}")
        {:error, reason}
    end
  end

  defp send_entity(endpoint, entity, schema, total, batch_size, now, opts) do
    send_pages(endpoint, entity, schema, 0, 0, total, batch_size, now, opts)
  end

  defp send_pages(endpoint, entity, schema, last_id, sent, total, batch_size, now, opts) do
    rows =
      schema
      |> where([s], s.id > ^last_id)
      |> order_by([s], asc: s.id)
      |> limit(^batch_size)
      |> Repo.all()

    case rows do
      [] ->
        {:ok, sent}

      rows ->
        events = Enum.map(rows, &Delivery.backfill_event(entity, &1, now))

        case post_with_retries(endpoint, Delivery.envelope("backfill", events, now), 1, opts) do
          :ok ->
            sent = sent + length(rows)
            progress(endpoint.id, entity, sent, total, now)

            send_pages(
              endpoint,
              entity,
              schema,
              List.last(rows).id,
              sent,
              total,
              batch_size,
              now,
              opts
            )

          {:error, _} = err ->
            err
        end
    end
  end

  defp post_with_retries(endpoint, envelope, attempt, opts) do
    case Delivery.post(endpoint, envelope) do
      {:ok, _} ->
        :ok

      {:error, reason} when attempt < @max_attempts ->
        Process.sleep(
          Keyword.get_lazy(opts, :sleep_ms, fn -> Delivery.backoff_seconds(attempt) * 1000 end)
        )

        Logger.warning(
          "ChangeStream.Backfill: retry #{attempt + 1}/#{@max_attempts}: #{inspect(reason)}"
        )

        post_with_retries(endpoint, envelope, attempt + 1, opts)

      {:error, _} = err ->
        err
    end
  end

  # Conditional UPDATE as the lock: 0 rows means someone else holds it.
  defp acquire(endpoint_id, now) do
    started = %{
      "entity" => nil,
      "sent" => 0,
      "total" => 0,
      "started_at" => DateTime.to_iso8601(now)
    }

    case Repo.update_all(
           from(e in Endpoint, where: e.id == ^endpoint_id and e.backfill_status != "running"),
           set: [
             backfill_status: "running",
             backfill_progress: started,
             backfill_error: nil,
             updated_at: DateTime.to_naive(now)
           ]
         ) do
      {1, _} ->
        :ok

      {0, _} ->
        if Repo.get(Endpoint, endpoint_id),
          do: {:error, :already_running},
          else: {:error, :not_found}
    end
  end

  defp progress(endpoint_id, entity, sent, total, started) do
    Repo.update_all(from(e in Endpoint, where: e.id == ^endpoint_id),
      set: [
        backfill_progress: %{
          "entity" => entity,
          "sent" => sent,
          "total" => total,
          "started_at" => DateTime.to_iso8601(started)
        }
      ]
    )
  end

  defp finish(endpoint_id, status, now, opts \\ []) do
    finished = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(e in Endpoint, where: e.id == ^endpoint_id),
      set: [
        backfill_status: status,
        backfill_error: Keyword.get(opts, :error),
        backfilled_at: if(status == "done", do: finished, else: nil),
        updated_at: DateTime.to_naive(now)
      ]
    )
  end
end
