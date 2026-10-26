defmodule TravelingPoet.Feedback do
  @moduledoc """
  What readers tell us about the app itself (card-137), as opposed to what
  they tell their poet (markers, reactions, chat).

  Two channels:

    * **Messages.** The form at `/feedback`, reached from Settings, the menu,
      the home page and `/support`: something broken, something to change,
      something missing. A visitor who is not signed in can write too
      (card-63) and leaves an email address so they can be answered. Each
      message pages the admins on Telegram (`{:feedback_received, id}` on
      `"admin_events"`, sent by `Telegram.Notifier`).

    * **The recommend question.** Under a fresh page, on the timing of
      `Feedback.Cadence`, the journal asks "How likely are you to recommend
      Traveling Poet to a friend?" (0-10), then "What would make it
      better?". The score is stored the moment it is tapped, so a reader who
      leaves before the second step still counts; the admins are paged once,
      when the reader sends or skips the second step
      (`{:nps_answered, id}`).

  Both are private words: neither leaves this database through the change
  stream. Signed-in rows go with the account (`on_delete: :delete_all`);
  `Accounts.Purge` also takes the signed-out ones sent from its address.
  """

  import Ecto.Query

  alias TravelingPoet.{Accounts, Repo}
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Feedback.{Cadence, Message, NpsResponse}

  # Enough for a reader with a lot to say; a guard against a script
  @daily_cap 5

  @doc "Messages one sender may send in a day."
  def daily_cap, do: @daily_cap

  @doc """
  Stores a message from `user`, or from a visitor (nil) who gives an email
  address, and tells the admins. `{:error, :too_many}` past the daily cap.
  """
  def create_message(user, attrs) do
    attrs = sender_attrs(user, attrs)

    if sent_today(attrs) >= @daily_cap do
      {:error, :too_many}
    else
      with {:ok, message} <- %Message{} |> Message.changeset(attrs) |> Repo.insert() do
        broadcast({:feedback_received, message.id})
        {:ok, message}
      end
    end
  end

  @doc "An empty changeset for the form."
  def change_message(attrs \\ %{}), do: Message.changeset(%Message{}, attrs)

  # A signed-in reader is the user, whatever the form says about an email
  defp sender_attrs(%User{id: id}, attrs),
    do: attrs |> stringify() |> Map.merge(%{"user_id" => id, "email" => nil})

  defp sender_attrs(nil, attrs), do: attrs |> stringify() |> Map.delete("user_id")

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  defp sent_today(attrs) do
    since = DateTime.add(DateTime.utc_now(), -1, :day)
    query = where(Message, [m], m.inserted_at >= ^DateTime.to_naive(since))

    query =
      case attrs do
        %{"user_id" => id} when not is_nil(id) ->
          where(query, [m], m.user_id == ^id)

        %{"email" => email} when is_binary(email) ->
          email = email |> String.trim() |> String.downcase()
          where(query, [m], m.email == ^email)

        _ ->
          nil
      end

    if query, do: Repo.aggregate(query, :count), else: 0
  end

  @doc "A message with its sender, or nil."
  def get_message(id), do: Message |> Repo.get(id) |> Repo.preload(:user)

  @doc "Messages newest first; `status: \"new\"` for the ones nobody has handled."
  def list_messages(opts \\ []) do
    Message
    |> then(fn q ->
      case opts[:status] do
        nil -> q
        status -> where(q, [m], m.status == ^status)
      end
    end)
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(^Keyword.get(opts, :limit, 200))
    |> preload(:user)
    |> Repo.all()
  end

  @doc "Marks a message handled (\"done\") or back to \"new\"."
  def set_status(%Message{} = message, status),
    do: message |> Message.status_changeset(status) |> Repo.update()

  @doc """
  Deletes the messages a visitor sent, signed out, from `email`. The signed-in
  ones go with the account; this is for `Accounts.Purge`.
  """
  def delete_signed_out(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    {count, _} =
      Message |> where([m], is_nil(m.user_id) and m.email == ^email) |> Repo.delete_all()

    count
  end

  # -- the recommend question --

  @doc "True when the journal should ask `user` under a page of `journey_day`."
  def nps_due?(%User{} = user, journey_day, now \\ DateTime.utc_now()) do
    Cadence.due?(
      %{
        journey_day: journey_day,
        last_answered_at: last_answered_at(user.id),
        dismissed_at: user.nps_prompt_dismissed_at
      },
      now
    )
  end

  defp last_answered_at(user_id) do
    NpsResponse
    |> where(user_id: ^user_id)
    |> select([r], max(r.inserted_at))
    |> Repo.one()
  end

  @doc "Stores the score the reader tapped, under the page it was asked on."
  def record_score(%User{} = user, score, entry_id \\ nil) do
    %NpsResponse{}
    |> NpsResponse.changeset(%{user_id: user.id, score: score, journal_entry_id: entry_id})
    |> Repo.insert()
  end

  @doc """
  The reader sent (or skipped) the words after their score: keeps the words,
  if any, and tells the admins, once per answer.
  """
  def finish_response(%NpsResponse{} = response, comment) do
    result =
      case comment && String.trim(comment) do
        text when is_binary(text) and text != "" ->
          response |> NpsResponse.changeset(%{comment: text}) |> Repo.update()

        _ ->
          {:ok, response}
      end

    with {:ok, response} <- result do
      broadcast({:nps_answered, response.id})
      {:ok, response}
    end
  end

  @doc "\"Not now\": the question rests for `Cadence.rest_days/0`."
  def dismiss_nps(%User{} = user) do
    Accounts.update_user(user, %{
      nps_prompt_dismissed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @doc "A response with its reader, or nil."
  def get_response(id), do: NpsResponse |> Repo.get(id) |> Repo.preload(:user)

  @doc "Responses newest first, with their readers."
  def recent_responses(limit \\ 100) do
    NpsResponse
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> limit(^limit)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  The last `days` of answers, counting each reader's latest one only: how
  many, how many promoters, passives and detractors, and the score (percent
  promoters minus percent detractors, nil with no answers).
  """
  def nps_summary(days \\ 90) do
    since = DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.to_naive()

    latest =
      NpsResponse
      |> where([r], r.inserted_at >= ^since)
      |> order_by([r], asc: r.inserted_at, asc: r.id)
      |> select([r], {r.user_id, r.score})
      |> Repo.all()
      |> Map.new()
      |> Map.values()

    summarize(latest)
  end

  @doc "The summary of a list of scores. Pure, for tests."
  def summarize(scores) do
    counts = Enum.frequencies_by(scores, &NpsResponse.bucket/1)
    total = length(scores)
    promoters = Map.get(counts, :promoter, 0)
    detractors = Map.get(counts, :detractor, 0)

    %{
      count: total,
      promoters: promoters,
      passives: Map.get(counts, :passive, 0),
      detractors: detractors,
      score: if(total > 0, do: round((promoters - detractors) * 100 / total))
    }
  end

  defp broadcast(event),
    do: Phoenix.PubSub.broadcast(TravelingPoet.PubSub, "admin_events", event)
end
