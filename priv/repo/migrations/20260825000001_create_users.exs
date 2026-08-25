defmodule TravelingPoet.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :name, :string
      add :avatar_url, :string
      add :is_admin, :boolean, default: false, null: false

      # Multi-provider identity: a user must have at least one of these
      # (enforced in the changeset, not the DB — Apple lands post-v1).
      add :google_id, :string
      add :apple_id, :string

      add :onboarding_completed, :boolean, default: false, null: false
      add :onboarding_step, :string

      # Telegram pairing (one central bot; chat_id identifies the user's DM)
      add :telegram_chat_id, :integer
      add :telegram_username, :string
      add :telegram_paired_at, :utc_datetime
      add :telegram_pair_token, :string
      add :telegram_pair_token_expires_at, :utc_datetime

      # Sprite / agent infrastructure (the poet's sandbox — one per user in v1).
      # These stay on users (not poets) so the ported GatewaySocket stack and
      # Provisioner read the same fields they did in alice-in-goals.
      add :sprite_name, :string
      add :sprite_url, :string
      add :gateway_token, :string
      add :agent_api_token, :string
      add :ai_provider, :string, default: "openrouter"
      add :agent_name, :string
      add :sprite_provisioned, :boolean, default: false, null: false
      add :device_public_key, :binary
      add :device_private_key, :binary
      add :openclaw_version, :string
      add :agent_onboarded_at, :utc_datetime

      # Quotas / cost caps
      add :daily_budget_cents, :integer, default: 100, null: false
      add :quota_exempt, :boolean, default: false, null: false

      timestamps()
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:google_id])
    create unique_index(:users, [:apple_id])
    create unique_index(:users, [:telegram_chat_id])
  end
end
