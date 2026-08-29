defmodule TravelingPoet.Messaging.Channel do
  @moduledoc """
  A user's DM with one of our bots (Telegram) or business numbers (WhatsApp).
  `external_id` is whatever that provider calls the conversation: a Telegram
  `chat_id` (stringified) or a WhatsApp `wa_id`. It stays nil between minting
  a pair token and the user actually sending the pairing message.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(telegram whatsapp)

  schema "messaging_channels" do
    field :provider, :string
    field :external_id, :string
    field :username, :string
    field :paired_at, :utc_datetime
    field :pair_token, :string
    field :pair_token_expires_at, :utc_datetime
    field :last_inbound_at, :utc_datetime

    belongs_to :user, TravelingPoet.Accounts.User

    timestamps()
  end

  def providers, do: @providers

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [
      :user_id,
      :provider,
      :external_id,
      :username,
      :paired_at,
      :pair_token,
      :pair_token_expires_at,
      :last_inbound_at
    ])
    |> validate_required([:user_id, :provider])
    |> validate_inclusion(:provider, @providers)
    |> unique_constraint([:user_id, :provider])
    |> unique_constraint([:provider, :external_id])
  end

  def paired?(%__MODULE__{external_id: id}) when is_binary(id) and id != "", do: true
  def paired?(_), do: false
end
