defmodule TravelingPoet.ChangeStream.Capture do
  @moduledoc """
  Finds what changed since the last tick by diffing content fingerprints, and
  writes the result to the outbox.

  Why a snapshot diff and not hooks at the write sites: SQLite gives us no
  change feed, Ecto's `insert/update/delete` cannot be wrapped centrally, and
  the two writes that matter most are invisible to application code anyway —
  `Accounts.Purge` deletes one user row and the database cascades through ten
  tables, and `Journal.replace_sections`/`Guide.replace_places` `delete_all`
  and re-insert on every run. Hashing every row on a timer sees all of it and
  needs nothing from the contexts.

  The whole pass runs in ONE transaction so the mirror is a consistent
  snapshot. That holds SQLite's write lock for the duration, which is
  milliseconds at today's size (a handful of users, a few hundred places).
  Nothing here does I/O other than the DB. Watch `usage_events` and
  `chat_messages`, the only tables that grow without bound: past ~100k rows
  this should move to per-entity transactions over `Repo.stream`.

  `updated_at` is deliberately not used as the change signal: it has second
  granularity, and `delete_all`/`insert_all` paths do not bump it.
  """

  import Ecto.Query
  require Logger

  alias TravelingPoet.ChangeStream.{Event, Fingerprint, Registry, Serializer}
  alias TravelingPoet.Repo

  # SQLite caps bound parameters per statement; 500 rows × ~5 columns is
  # comfortably under it.
  @chunk 500

  @doc """
  One capture pass. Returns counts. `emit: false` refreshes fingerprints
  without writing events — used to seed on first registration so the mirror
  starts from a backfill, not from a storm of "inserts" for rows that have
  existed for months.
  """
  def tick(now \\ DateTime.utc_now(), opts \\ []) do
    emit? = Keyword.get(opts, :emit, true)
    occurred_at = DateTime.truncate(now, :second)

    {:ok, totals} =
      Repo.transaction(fn ->
        Enum.reduce(Registry.streamed(), %{inserts: 0, updates: 0, deletes: 0}, fn {entity,
                                                                                    schema},
                                                                                   acc ->
          counts = diff_entity(entity, schema, occurred_at, emit?)
          Map.merge(acc, counts, fn _k, a, b -> a + b end)
        end)
      end)

    if emit? and totals != %{inserts: 0, updates: 0, deletes: 0} do
      Logger.info(
        "ChangeStream.Capture: +#{totals.inserts} ~#{totals.updates} -#{totals.deletes}"
      )
    end

    totals
  end

  @doc "Refresh fingerprints without emitting events."
  def seed(now \\ DateTime.utc_now()), do: tick(now, emit: false)

  @doc "Drops every fingerprint; the next tick would re-emit everything as inserts."
  def reset, do: Repo.delete_all(Fingerprint)

  defp diff_entity(entity, schema, occurred_at, emit?) do
    known =
      Fingerprint
      |> where([f], f.entity == ^entity)
      |> select([f], {f.row_id, f.fingerprint})
      |> Repo.all()
      |> Map.new()

    rows = Repo.all(from(s in schema, order_by: s.id))

    {events, changed, seen} =
      Enum.reduce(rows, {[], [], MapSet.new()}, fn row, {events, changed, seen} ->
        record = Serializer.encode(entity, row)
        fp = Serializer.fingerprint(record)
        seen = MapSet.put(seen, row.id)

        case Map.get(known, row.id) do
          ^fp ->
            {events, changed, seen}

          previous ->
            action = if previous, do: "update", else: "insert"
            event = event(entity, row.id, action, record, occurred_at)
            fingerprint = %{entity: entity, row_id: row.id, fingerprint: fp}
            {[event | events], [fingerprint | changed], seen}
        end
      end)

    gone = known |> Map.keys() |> Enum.reject(&MapSet.member?(seen, &1))

    delete_events =
      Enum.map(gone, &event(entity, &1, "delete", %{"id" => &1}, occurred_at))

    events = Enum.reverse(events) ++ delete_events

    if emit? and events != [] do
      events
      |> Enum.chunk_every(@chunk)
      |> Enum.each(&Repo.insert_all(Event, &1))
    end

    changed
    |> Enum.chunk_every(@chunk)
    |> Enum.each(
      &Repo.insert_all(Fingerprint, &1,
        on_conflict: {:replace, [:fingerprint]},
        conflict_target: [:entity, :row_id]
      )
    )

    gone
    |> Enum.chunk_every(@chunk)
    |> Enum.each(fn ids ->
      Repo.delete_all(from(f in Fingerprint, where: f.entity == ^entity and f.row_id in ^ids))
    end)

    # Counts are of events WRITTEN; a seed writes none.
    if emit? do
      %{
        inserts: Enum.count(events, &(&1.action == "insert")),
        updates: Enum.count(events, &(&1.action == "update")),
        deletes: length(gone)
      }
    else
      %{inserts: 0, updates: 0, deletes: 0}
    end
  end

  defp event(entity, row_id, action, payload, occurred_at) do
    %{entity: entity, row_id: row_id, action: action, payload: payload, occurred_at: occurred_at}
  end
end
