defmodule TravelingPoet.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :avatar_url, :string
    field :is_admin, :boolean, default: false

    # Multi-provider identity: at least one of these must be present.
    field :google_id, :string
    field :apple_id, :string

    field :onboarding_completed, :boolean, default: false
    field :onboarding_step, :string
    # Stamped (debounced) on every authenticated page load, so the admin
    # report can tell "quiet but here" from "gone".
    field :last_seen_at, :utc_datetime

    field :telegram_chat_id, :integer
    field :telegram_username, :string
    field :telegram_paired_at, :utc_datetime
    field :telegram_pair_token, :string
    field :telegram_pair_token_expires_at, :utc_datetime

    # Sprite/agent fields (same names as alice-in-goals so the ported
    # GatewaySocket stack and Provisioner work unchanged)
    field :sprite_name, :string
    field :sprite_url, :string
    field :gateway_token, :string
    field :agent_api_token, :string
    field :ai_provider, :string, default: "openrouter"
    field :agent_name, :string
    field :sprite_provisioned, :boolean, default: false
    field :device_public_key, :binary
    field :device_private_key, :binary
    field :openclaw_version, :string
    field :agent_onboarded_at, :utc_datetime

    field :daily_budget_cents, :integer, default: 100
    field :quota_exempt, :boolean, default: false

    # Credits (milli-credits; see TravelingPoet.Credits)
    field :credits_balance, :integer, default: 0
    field :low_credits_notified_at, :utc_datetime

    has_one :poet, TravelingPoet.Poets.Poet

    timestamps()
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :email,
      :name,
      :avatar_url,
      :is_admin,
      :google_id,
      :apple_id,
      :onboarding_completed,
      :onboarding_step,
      :last_seen_at,
      :telegram_chat_id,
      :telegram_username,
      :telegram_paired_at,
      :telegram_pair_token,
      :telegram_pair_token_expires_at,
      :sprite_name,
      :sprite_url,
      :gateway_token,
      :agent_api_token,
      :ai_provider,
      :agent_name,
      :sprite_provisioned,
      :device_public_key,
      :device_private_key,
      :openclaw_version,
      :agent_onboarded_at,
      :daily_budget_cents,
      :quota_exempt,
      :credits_balance,
      :low_credits_notified_at
    ])
    |> validate_required([:email])
    |> validate_has_identity()
    |> unique_constraint(:email)
    |> unique_constraint(:google_id)
    |> unique_constraint(:apple_id)
    |> unique_constraint(:telegram_chat_id)
  end

  # A user must be reachable through at least one OAuth identity.
  defp validate_has_identity(changeset) do
    google = get_field(changeset, :google_id)
    apple = get_field(changeset, :apple_id)

    if google in [nil, ""] and apple in [nil, ""] do
      add_error(changeset, :google_id, "at least one sign-in identity is required")
    else
      changeset
    end
  end
end
