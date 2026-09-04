defmodule TravelingPoet.WebPush.Subscription do
  @moduledoc """
  One browser's Web Push subscription (RFC 8030). A user has one per device
  and browser profile they turned notifications on from; the endpoint is the
  identity, so re-subscribing from the same browser updates rather than dupes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string
    field :user_agent, :string
    field :last_sent_at, :utc_datetime
    field :last_error, :string

    belongs_to :user, TravelingPoet.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:user_id, :endpoint, :p256dh, :auth, :user_agent, :last_sent_at, :last_error])
    |> validate_required([:user_id, :endpoint, :p256dh, :auth])
    |> validate_format(:endpoint, ~r/^https:\/\//, message: "must be an https URL")
    |> validate_length(:endpoint, max: 2048)
    |> validate_length(:user_agent, max: 255)
    |> unique_constraint(:endpoint)
  end
end
