defmodule TravelingPoet.Asks do
  @moduledoc """
  The poet's questions to its reader, asked in chat on days the app chooses.

  The app decides WHEN (`Asks.Cadence`, surfaced as `ask_reader` in
  `/api/agent/context`); the poet writes the question in its own voice and
  hands it over with its `ask_reader` tool; the app keeps it (`create/2`),
  shows it in the chat and sends it to the reader's devices and Telegram
  (the `"asks"` PubSub topic). The reader answers in chat, on the web or in
  Telegram; a topic the poet takes from that answer becomes active at once
  (`Topics.add_from_ask/3`).
  """

  import Ecto.Query

  alias TravelingPoet.{Chat, Repo}
  alias TravelingPoet.Asks.{Ask, Cadence}
  alias TravelingPoet.Journal.Entry
  alias TravelingPoet.Topics.Topic

  # How long an ask waits for a reply before it counts as unanswered.
  @reply_window_days 3

  def reply_window_days, do: @reply_window_days

  @doc """
  What the poet is told today: `%{about, reason}` when it should ask, else
  nil. The one place `Cadence` meets the database.
  """
  def due(poet, today \\ Date.utc_today()) do
    case Cadence.due(facts(poet.id), today) do
      {:ask, reason} -> %{about: "topics", reason: reason}
      :no -> nil
    end
  end

  @doc false
  def facts(poet_id) do
    now = DateTime.utc_now()

    %{
      published:
        Repo.aggregate(
          from(e in Entry, where: e.poet_id == ^poet_id and e.status == "published"),
          :count
        ),
      active_topics:
        Repo.aggregate(
          from(t in Topic, where: t.poet_id == ^poet_id and t.status == "active"),
          :count
        ),
      newest_topic_on:
        from(t in Topic,
          where: t.poet_id == ^poet_id and t.status == "active",
          select: max(t.inserted_at)
        )
        |> Repo.one()
        |> then(&(&1 && NaiveDateTime.to_date(&1))),
      asks:
        poet_id
        |> history(12)
        |> Enum.map(fn a ->
          %{
            asked_on: NaiveDateTime.to_date(a.inserted_at),
            answered: a.status != "open",
            open: open?(a, now)
          }
        end)
    }
  end

  @doc "The poet's most recent asks, newest first."
  def history(poet_id, limit \\ 20) do
    Ask
    |> where(poet_id: ^poet_id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "The ask still waiting on the reader, if any."
  def open_ask(poet_id) do
    now = DateTime.utc_now()

    case history(poet_id, 1) do
      [%Ask{} = ask] -> if open?(ask, now), do: ask
      _ -> nil
    end
  end

  @doc """
  The latest ask the reader is still in the middle of: open, or replied to
  within the reply window. A topic taken from the reader's answer is tied
  to this one (`Topics.add_from_ask/3`).
  """
  def answerable(poet_id, ask_id) when is_integer(ask_id) do
    cutoff = window_start(DateTime.utc_now())

    Ask
    |> where(poet_id: ^poet_id, id: ^ask_id)
    |> where([a], a.inserted_at >= ^cutoff)
    |> Repo.one()
  end

  def answerable(poet_id, ask_id) when is_binary(ask_id) do
    case Integer.parse(ask_id) do
      {id, ""} -> answerable(poet_id, id)
      _ -> nil
    end
  end

  def answerable(_poet_id, _ask_id), do: nil

  defp open?(%Ask{status: "open", inserted_at: at}, now),
    do: NaiveDateTime.compare(at, window_start(now)) != :lt

  defp open?(_ask, _now), do: false

  defp window_start(now),
    do: now |> DateTime.add(-@reply_window_days, :day) |> DateTime.to_naive()

  @doc """
  Keeps the poet's question, puts it in the chat as the poet's message and
  announces it. Refuses when today is not a day to ask: the app decides,
  and a poet that asks anyway is told so.

  Returns `{:ok, ask}`, `{:error, :not_due}` or `{:error, changeset}`.
  """
  def create(poet, question, today \\ Date.utc_today()) do
    with %{about: about, reason: reason} <- due(poet, today) || {:error, :not_due},
         {:ok, {ask, message}} <- insert(poet, about, reason, question) do
      broadcast(ask, message)
      {:ok, ask}
    end
  end

  defp insert(poet, about, reason, question) do
    Repo.transaction(fn ->
      changeset =
        Ask.changeset(%Ask{}, %{
          user_id: poet.user_id,
          poet_id: poet.id,
          about: about,
          reason: reason,
          question: question
        })

      with {:ok, ask} <- Repo.insert(changeset),
           {:ok, message} <-
             Chat.create_message(%{
               user_id: poet.user_id,
               role: "agent",
               content: ask.question,
               channel: "web"
             }),
           {:ok, ask} <-
             ask |> Ecto.Changeset.change(chat_message_id: message.id) |> Repo.update() do
        {ask, message}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp broadcast(ask, message) do
    Phoenix.PubSub.broadcast(TravelingPoet.PubSub, "asks", {:reader_asked, ask.user_id, ask.id})

    Phoenix.PubSub.broadcast(
      TravelingPoet.PubSub,
      "user:#{ask.user_id}",
      {:poet_asked, message}
    )
  end

  def get(id), do: Repo.get(Ask, id)

  @doc """
  The reader wrote in chat (any channel but the app's own triggers): an
  open ask counts as replied, whatever they said. Called from
  `Chat.create_message/1`.
  """
  def note_reader_message(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Ask
    |> where(user_id: ^user_id, status: "open")
    |> where([a], a.inserted_at >= ^window_start(now))
    |> Repo.update_all(set: [status: "replied", replied_at: now])

    :ok
  end

  @doc "A topic came of the reader's answer."
  def mark_answered(%Ask{} = ask) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ask
    |> Ecto.Changeset.change(
      status: "answered",
      answered_at: now,
      replied_at: ask.replied_at || now
    )
    |> Repo.update()
  end
end
