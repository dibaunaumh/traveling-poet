defmodule TravelingPoet.Asks.Ask do
  @moduledoc """
  A question the poet put to its reader in chat, on a day the app chose
  (`Asks.Cadence`). `about` is "topics" (what subjects they follow) or a
  domain (`Topic.domains/0`: their taste in music, books...).

  `status`: "open" until the reader writes anything in chat, then "replied";
  "answered" once a topic came of it. An open ask older than
  `Asks.reply_window_days/0` counts as unanswered; nothing sweeps it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @abouts ["topics" | TravelingPoet.Topics.Topic.domains()]
  @reasons ~w(no_topics domain check_in)
  @statuses ~w(open replied answered)

  schema "reader_asks" do
    field :about, :string, default: "topics"
    field :reason, :string
    field :question, :string
    field :status, :string, default: "open"
    field :replied_at, :utc_datetime
    field :answered_at, :utc_datetime

    belongs_to :user, TravelingPoet.Accounts.User
    belongs_to :poet, TravelingPoet.Poets.Poet
    belongs_to :chat_message, TravelingPoet.Chat.ChatMessage

    timestamps()
  end

  def abouts, do: @abouts
  def reasons, do: @reasons

  @doc false
  def changeset(ask, attrs) do
    ask
    |> cast(attrs, [:user_id, :poet_id, :about, :reason, :question, :status, :chat_message_id])
    |> update_change(:question, &String.trim/1)
    |> validate_required([:user_id, :poet_id, :about, :question])
    |> validate_length(:question, min: 5, max: 280)
    |> validate_inclusion(:about, @abouts)
    |> validate_inclusion(:reason, @reasons)
    |> validate_inclusion(:status, @statuses)
  end
end
