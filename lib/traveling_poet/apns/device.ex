defmodule TravelingPoet.Apns.Device do
  @moduledoc "An install of the iOS app that asked for notifications (`apns_devices`)."
  use Ecto.Schema
  import Ecto.Changeset

  @environments ~w(sandbox production)

  schema "apns_devices" do
    field :token, :string
    field :environment, :string, default: "production"
    field :last_sent_at, :utc_datetime
    field :last_error, :string

    belongs_to :user, TravelingPoet.Accounts.User

    timestamps()
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [:user_id, :token, :environment, :last_sent_at, :last_error])
    |> validate_required([:user_id, :token, :environment])
    |> validate_inclusion(:environment, @environments)
    # APNs tokens are hex; today 64 characters, and Apple says not to assume
    |> validate_format(:token, ~r/\A[0-9a-fA-F]{32,200}\z/)
    |> unique_constraint(:token)
  end
end
