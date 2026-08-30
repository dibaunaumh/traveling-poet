defmodule TravelingPoet.Repo.Migrations.CreateMessagingChannels do
  use Ecto.Migration

  @moduledoc """
  Generalises Telegram pairing into a per-provider `messaging_channels` table
  so a user can be reachable on Telegram, WhatsApp, or both. Backfills the
  existing `users.telegram_*` columns and then drops them.
  """

  def up do
    create table(:messaging_channels) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      # Telegram chat_id (stringified) or WhatsApp wa_id; nil until paired.
      add :external_id, :string
      add :username, :string
      add :paired_at, :utc_datetime
      add :pair_token, :string
      add :pair_token_expires_at, :utc_datetime
      # Last message *from* the user — WhatsApp only allows free-form replies
      # inside 24h of this.
      add :last_inbound_at, :utc_datetime

      timestamps()
    end

    # One channel row per user per provider; minting a pair link upserts it.
    create unique_index(:messaging_channels, [:user_id, :provider])
    # NULL external_ids stay distinct in SQLite, so unpaired rows don't clash.
    create unique_index(:messaging_channels, [:provider, :external_id])
    create index(:messaging_channels, [:pair_token])

    execute """
    INSERT INTO messaging_channels
      (user_id, provider, external_id, username, paired_at, pair_token,
       pair_token_expires_at, inserted_at, updated_at)
    SELECT id, 'telegram', CAST(telegram_chat_id AS TEXT), telegram_username,
           COALESCE(telegram_paired_at, datetime('now')), NULL, NULL,
           datetime('now'), datetime('now')
    FROM users
    WHERE telegram_chat_id IS NOT NULL
    """

    drop unique_index(:users, [:telegram_chat_id])

    alter table(:users) do
      remove :telegram_chat_id
      remove :telegram_username
      remove :telegram_paired_at
      remove :telegram_pair_token
      remove :telegram_pair_token_expires_at
    end
  end

  def down do
    alter table(:users) do
      add :telegram_chat_id, :integer
      add :telegram_username, :string
      add :telegram_paired_at, :utc_datetime
      add :telegram_pair_token, :string
      add :telegram_pair_token_expires_at, :utc_datetime
    end

    execute """
    UPDATE users SET
      telegram_chat_id = (
        SELECT CAST(external_id AS INTEGER) FROM messaging_channels c
        WHERE c.user_id = users.id AND c.provider = 'telegram'
      ),
      telegram_username = (
        SELECT username FROM messaging_channels c
        WHERE c.user_id = users.id AND c.provider = 'telegram'
      ),
      telegram_paired_at = (
        SELECT paired_at FROM messaging_channels c
        WHERE c.user_id = users.id AND c.provider = 'telegram'
      )
    """

    create unique_index(:users, [:telegram_chat_id])

    drop table(:messaging_channels)
  end
end
