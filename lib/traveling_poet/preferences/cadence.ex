defmodule TravelingPoet.Preferences.Cadence do
  @moduledoc """
  Decides whether to ask the reader anything today.

  The app owns this, not the model: an agent told to "ask sometimes" asks
  every time. `ask?/3` is called from both the journal page and the agent's
  context payload, so the question the reader sees and the question the poet
  prepares can never disagree.

  The rules are shaped by what silence means. Early on, nothing is known and
  attention is highest, so ask. Once preferences exist, asking becomes rare.
  If prompts go unanswered, back off hard — a nagging footer is how you lose
  the last signal you have. If entries stop being opened at all, ask once
  more, but ask a bigger question.
  """

  import Ecto.Query

  alias TravelingPoet.Journal.Entry
  alias TravelingPoet.Preferences
  alias TravelingPoet.Preferences.EntryPrompt
  alias TravelingPoet.Repo
  alias TravelingPoet.Topics

  @cold_start_entries 3
  @min_preferences 3
  @steady_state_every 4
  @days_after_answer 5
  @max_unanswered_streak 2
  @backoff_every 10
  # The first excursions into a topic always ask: they are the fastest way to
  # learn whether the topic was worth a day off the road.
  @excursion_check_ins 3

  def cold_start_entries, do: @cold_start_entries
  def excursion_check_ins, do: @excursion_check_ins

  @doc """
  `{true, reason}` when this entry should carry a question, `false` otherwise.
  The reason is for logs and tests — it says which rule fired.
  """
  def ask?(poet, entry, now \\ DateTime.utc_now())

  def ask?(_poet, nil, _now), do: false

  def ask?(poet, entry, now) do
    cond do
      # One prompt per entry, ever — answered, dismissed or merely shown.
      prompt_for(entry.id) != nil -> false
      app_owned?(entry) -> {true, :excursion}
      disengaged?(poet, entry) -> {true, :disengaged}
      unanswered_streak(poet.id) > @max_unanswered_streak -> backoff(poet, entry)
      cold_start?(poet, entry) -> {true, :cold_start}
      answered_recently?(poet.id, now) -> false
      due_by_interval?(poet, entry) -> {true, :steady_state}
      true -> false
    end
  end

  @doc """
  Whether the question under this entry belongs to the app, not the poet:
  one of the first excursions into a topic. `attach_agent_prompt/2` refuses
  to replace it, so a poet that ignores its skill loses nothing.
  """
  def app_owned?(entry) do
    case Topics.excursion_of(entry) do
      %{topic_id: topic_id} when is_integer(topic_id) ->
        Topics.published_excursions_before(topic_id, entry.entry_date) < @excursion_check_ins

      _ ->
        false
    end
  end

  # Nothing is known yet and the reader is paying the most attention they ever
  # will. Ask on the first few entries, and keep asking until the poet has
  # enough to go on.
  defp cold_start?(poet, entry) do
    published_before(poet.id, entry) < @cold_start_entries or
      length(Preferences.list_active(poet.id)) < @min_preferences
  end

  # They have stopped opening entries. The next one they do open gets a
  # question — and a broader one (see `question_kind/1`).
  #
  # Only entries BEFORE this one count: the entry being read right now was
  # published moments ago and is unopened by definition, so including it would
  # make almost every reader look disengaged.
  defp disengaged?(poet, entry) do
    recent =
      Entry
      |> where(poet_id: ^poet.id, status: "published")
      |> where([e], e.entry_date < ^entry.entry_date)
      |> order_by(desc: :entry_date)
      |> limit(2)
      |> Repo.all()

    length(recent) == 2 and Enum.all?(recent, &is_nil(&1.owner_viewed_at))
  end

  defp backoff(poet, entry) do
    if rem(published_before(poet.id, entry), @backoff_every) == 0,
      do: {true, :backoff},
      else: false
  end

  defp due_by_interval?(poet, entry) do
    rem(published_before(poet.id, entry), @steady_state_every) == 0
  end

  defp answered_recently?(poet_id, now) do
    cutoff = DateTime.add(now, -@days_after_answer, :day)

    prompt_query(poet_id)
    |> where([p], not is_nil(p.answered_at) and p.answered_at >= ^cutoff)
    |> Repo.exists?()
  end

  # Consecutive prompts shown and never acted on, newest first.
  defp unanswered_streak(poet_id) do
    prompt_query(poet_id)
    |> order_by([p], desc: p.inserted_at)
    |> limit(10)
    |> Repo.all()
    |> Enum.take_while(&(is_nil(&1.answered_at) and is_nil(&1.dismissed_at)))
    |> length()
  end

  defp prompt_query(poet_id) do
    from(p in EntryPrompt,
      join: e in Entry,
      on: e.id == p.journal_entry_id,
      where: e.poet_id == ^poet_id
    )
  end

  defp published_before(poet_id, entry) do
    Entry
    |> where(poet_id: ^poet_id, status: "published")
    |> where([e], e.entry_date < ^entry.entry_date)
    |> select([e], count(e.id))
    |> Repo.one()
  end

  def prompt_for(entry_id), do: Repo.get_by(EntryPrompt, journal_entry_id: entry_id)

  @doc """
  Disengagement deserves a different question. Asking someone who has stopped
  reading to choose between museums and markets misses the point.
  """
  def question_kind(:disengaged), do: :broad
  def question_kind(:excursion), do: :excursion
  def question_kind(_reason), do: :narrow
end
