defmodule TravelingPoet.Chat.ChatMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @channels ~w(web telegram system)

  schema "chat_messages" do
    field :role, :string
    field :content, :string
    field :response_id, :string
    field :attachments, :map, default: %{}
    field :channel, :string, default: "web"

    belongs_to :user, TravelingPoet.Accounts.User

    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:user_id, :role, :content, :response_id, :attachments, :channel])
    |> validate_required([:user_id, :role, :content])
    |> validate_inclusion(:role, ["user", "agent"])
    |> validate_inclusion(:channel, @channels)
  end
end
