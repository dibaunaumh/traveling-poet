defmodule TravelingPoet.Chat do
  @moduledoc """
  Context module for chat message persistence.
  """

  import Ecto.Query
  alias TravelingPoet.Repo
  alias TravelingPoet.Chat.ChatMessage

  @doc """
  The conversation as the user should see it.

  Triggers the app sends on the user's behalf — `/travel-and-journal`,
  `/onboard` — are persisted on the "system" channel so the agent keeps its
  context, but showing them back reads as if the user typed a command they
  never typed. The poet's replies on that channel are real content and stay.
  """
  def list_messages(user_id) do
    ChatMessage
    |> where(user_id: ^user_id)
    |> where([m], not (m.role == "user" and m.channel == "system"))
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  def list_recent_messages(user_id, limit \\ 100) do
    ChatMessage
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  Saves a message. A reader's own message (web or Telegram, not the app's
  triggers) also counts as their reply to an open ask (`Asks`).
  """
  def create_message(attrs) do
    result =
      %ChatMessage{}
      |> ChatMessage.changeset(attrs)
      |> Repo.insert()

    with {:ok, %ChatMessage{role: "user", channel: channel} = msg} when channel != "system" <-
           result do
      TravelingPoet.Asks.note_reader_message(msg.user_id)
    end

    result
  end

  @doc """
  Whether an identical agent message was persisted in the last `minutes` —
  the scheduler's dedup guard: when the journal page is open during a
  scheduled run, the ChatSidebarComponent persists the streamed reply too.
  Content+recency (NOT response_id: the gateway's chat-history path emits the
  CONSTANT id "chat-history", which would dedup every future reply forever).
  """
  def recent_agent_message_exists?(user_id, content, minutes \\ 10) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -minutes * 60, :second)

    ChatMessage
    |> where(user_id: ^user_id, role: "agent", content: ^content)
    |> where([m], m.inserted_at >= ^cutoff)
    |> Repo.exists?()
  end

  def get_last_response_id(user_id) do
    ChatMessage
    |> where(user_id: ^user_id)
    |> where([m], not is_nil(m.response_id))
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> select([m], m.response_id)
    |> Repo.one()
  end
end
