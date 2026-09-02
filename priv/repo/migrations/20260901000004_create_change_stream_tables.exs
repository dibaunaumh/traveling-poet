defmodule TravelingPoet.Repo.Migrations.CreateChangeStreamTables do
  use Ecto.Migration

  # The change stream mirrors every table to admin-registered webhooks so
  # external operator agents can hold a copy of the world model.
  #
  # Why three tables and no Redis: the app is SQLite on one Fly machine, and
  # SQLite has no change-data-capture (no triggers we can listen to, no
  # LISTEN/NOTIFY, no WAL decoding) and Ecto's write callbacks are not
  # overridable. So changes are found by diffing a content fingerprint per row
  # (`change_stream_fingerprints`) on a timer, queued in an outbox
  # (`change_stream_events`) and delivered per endpoint from a cursor
  # (`change_stream_endpoints.cursor_event_id`). Tables rather than memory or
  # Redis for the same reason the geocode cache is a table: the app restarts on
  # every deploy and there is exactly one machine, so a table is the simplest
  # thing that survives.
  def change do
    create table(:change_stream_endpoints) do
      add :url, :string, null: false
      # Sent as `Authorization: Bearer` so the receiver can gate its route.
      # Plaintext, like users.agent_api_token — there is no encryption at
      # rest anywhere in this app yet.
      add :auth_token, :string, null: false
      # HMAC key for the x-poet-signature header; generated, shown once.
      add :signing_secret, :string, null: false
      # active | paused | failing. Delete the row to disable; paused keeps the
      # cursor, failing is a flag that still retries.
      add :status, :string, null: false, default: "active"
      add :cursor_event_id, :integer, null: false, default: 0
      add :consecutive_failures, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime
      add :last_success_at, :utc_datetime
      add :last_failure_at, :utc_datetime
      add :last_error, :string
      add :last_status_code, :integer
      # idle | running | done | failed. "running" is also the single-runner
      # lock for the backfill task.
      add :backfill_status, :string, null: false, default: "idle"
      add :backfill_progress, :map, null: false, default: %{}
      add :backfill_error, :string
      add :backfilled_at, :utc_datetime

      timestamps()
    end

    # The outbox. The integer id is the cursor and the ordering, so no
    # timestamps column beyond occurred_at (which the retention prune uses).
    create table(:change_stream_events) do
      add :entity, :string, null: false
      add :row_id, :integer, null: false
      add :action, :string, null: false
      add :payload, :map, null: false
      add :occurred_at, :utc_datetime, null: false
    end

    create index(:change_stream_events, [:occurred_at])

    # Last-seen content hash per row. A rebuildable cache: dropping it and
    # re-seeding costs one silent pass, nothing else.
    create table(:change_stream_fingerprints) do
      add :entity, :string, null: false
      add :row_id, :integer, null: false
      add :fingerprint, :string, null: false
    end

    create unique_index(:change_stream_fingerprints, [:entity, :row_id])
  end
end
