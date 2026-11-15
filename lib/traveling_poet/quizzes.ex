defmodule TravelingPoet.Quizzes do
  @moduledoc """
  Quiz day (card-140, dec-021): every few weeks the poet spends a day
  quizzing its reader on the curious facts of its past pages instead of
  writing a new one, and the reader gets a score and the poet's closing note.

  The app owns the decisions, the poet the words. `Cadence` decides the day
  and the travel plan carries it (`travel.day == "quiz"`, `travel.quiz`);
  `handout/2` chooses the material (paragraphs the reader actually read come
  first, past drawings, places); the poet writes the questions from it and
  sends them with `journal_put_quiz`, and `put/3` checks every one against
  what was really written, the way `Books.Quotes` checks a quote. A
  "which came first" answer is set here, from the dates, never by the poet.

  A quiz day is free (`Credits.debit_daily_run/4`) and, like an excursion, a
  day off the road: it does not count against the stay (`days_off_since/2`).
  The questions live in their own tables, not in sections, so Listen, the
  book and the page email never read the answers out.
  """

  import Ecto.Query

  alias TravelingPoet.{Journal, Repo}
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Journal.{Entry, Paragraphs}
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.Quizzes.{Answer, Cadence, Question, Quiz}
  alias TravelingPoet.Reading.ParagraphRead

  @taken ~w(written published)

  @candidates 18
  @per_page 2
  @drawings 6
  @excerpt_max 600

  @min_questions 4
  @max_questions 8
  @prompt_max 300
  @option_max 160
  @aside_max 300
  @note_max 600
  @letters ~w(a b c d)

  ## Who and when

  @doc """
  Whether quiz days are on for this reader: `:quiz_enabled` is "all",
  "admins" (the first weeks) or "off". A day the app holds for a quiz
  (`schedule_for/2`) is a quiz day whatever this says.
  """
  def enabled_for?(%User{} = user) do
    case Application.get_env(:traveling_poet, :quiz_enabled, "admins") do
      "all" -> true
      "admins" -> user.is_admin == true
      _ -> false
    end
  end

  def enabled_for?(%Poet{user_id: user_id}) do
    case Repo.get(User, user_id) do
      nil -> false
      user -> enabled_for?(user)
    end
  end

  @doc "Whether the cadence calls for a quiz today. Nil when not; the reason otherwise."
  def due(%Poet{} = poet, today \\ Date.utc_today()) do
    with true <- enabled_for?(poet),
         {:quiz, reason} <- Cadence.due(facts(poet.id, today), today) do
      reason
    else
      _ -> nil
    end
  end

  @doc false
  def facts(poet_id, today) do
    last =
      Repo.one(
        from q in Quiz,
          where: q.poet_id == ^poet_id and q.status in @taken and q.scheduled_for < ^today,
          select: max(q.scheduled_for)
      )

    published = from(e in Entry, where: e.poet_id == ^poet_id and e.status == "published")

    %{
      published: Repo.aggregate(published, :count),
      last_quiz_on: last,
      published_since_last:
        if(last,
          do: Repo.aggregate(where(published, [e], e.entry_date > ^last), :count),
          else: 0
        )
    }
  end

  @doc "The quiz held for or written on this date, with its questions; nil if none."
  def for_day(poet_id, %Date{} = date) do
    Quiz
    |> where(poet_id: ^poet_id, scheduled_for: ^date)
    |> preload(:questions)
    |> Repo.one()
  end

  @doc """
  Holds the day for a quiz, so a retried run makes the same decision and
  the publish reply knows the page should carry one. Idempotent.
  """
  def hold_day(%Poet{} = poet, %Date{} = date, source \\ "cadence") do
    case for_day(poet.id, date) do
      %Quiz{} = quiz ->
        {:ok, quiz}

      nil ->
        %Quiz{}
        |> Quiz.changeset(%{poet_id: poet.id, scheduled_for: date, source: source})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:poet_id, :scheduled_for])
        |> case do
          {:ok, _} -> {:ok, for_day(poet.id, date)}
          error -> error
        end
    end
  end

  @doc """
  For an admin over rpc: make `date` this poet's quiz day, whatever the
  cadence or the rollout flag says.
  """
  def schedule_for(%Poet{} = poet, %Date{} = date \\ Date.utc_today()),
    do: hold_day(poet, date, "admin")

  @doc """
  Quiz days taken since the poet arrived where it is. Like an excursion, a
  quiz day is off the road and does not count against the stay.
  """
  def days_off_since(poet_id, %Date{} = arrived_on) do
    Repo.one(
      from q in Quiz,
        where:
          q.poet_id == ^poet_id and q.status in @taken and q.scheduled_for >= ^arrived_on and
            not is_nil(q.journal_entry_id),
        select: count(q.id)
    )
  end

  def days_off_since(_poet_id, nil), do: 0

  @doc "The quiz on an entry, or nil when the entry is an ordinary page."
  def quiz_of(nil), do: nil

  def quiz_of(%{id: nil}), do: nil

  def quiz_of(entry) do
    case Map.get(entry, :quiz) do
      %Quiz{} = quiz ->
        quiz

      _ ->
        Quiz
        |> where(journal_entry_id: ^entry.id)
        |> preload(:questions)
        |> Repo.one()
    end
  end

  @doc "Whether this entry's day was held for a quiz (whether or not the poet wrote one)."
  def quiz_day?(%{poet_id: poet_id, entry_date: %Date{} = date}) when is_integer(poet_id),
    do: Repo.exists?(from q in Quiz, where: q.poet_id == ^poet_id and q.scheduled_for == ^date)

  def quiz_day?(_), do: false

  @doc "The entry went out; its quiz is taken for good."
  def mark_published(entry_id) do
    Quiz
    |> where(journal_entry_id: ^entry_id)
    |> Repo.update_all(set: [status: "published", updated_at: DateTime.utc_now()])

    :ok
  end

  ## Playing

  @doc "The quiz on a published entry, ready to play (drawings and sources loaded); nil if none."
  def playable(nil), do: nil

  def playable(%Entry{status: "published"} = entry) do
    Quiz
    |> where(journal_entry_id: ^entry.id)
    |> preload(questions: [:media, :source_entry])
    |> Repo.one()
    |> case do
      %Quiz{questions: [_ | _]} = quiz -> quiz
      _ -> nil
    end
  end

  def playable(_entry), do: nil

  @doc "`playable/1` for many entries at once: `%{entry_id => quiz}` (the book, the bundle)."
  def playable_by_entry([]), do: %{}

  def playable_by_entry(entry_ids) do
    Quiz
    |> where([q], q.journal_entry_id in ^entry_ids)
    |> preload(questions: [:media, :source_entry])
    |> Repo.all()
    |> Enum.reject(&(&1.questions == []))
    |> Map.new(&{&1.journal_entry_id, &1})
  end

  @doc "The owner's answers so far, `%{question_id => option_id}`."
  def answers_for(%Quiz{questions: questions}, user_id) do
    ids = Enum.map(questions, & &1.id)

    from(a in Answer,
      where: a.user_id == ^user_id and a.question_id in ^ids,
      select: {a.question_id, a.option_id}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Keeps the owner's answer to one question. One try: a second answer to the
  same question is ignored and the first stands. Only the poet's own reader
  is kept (dec-021); anyone else plays in the page.
  """
  def answer(%Quiz{} = quiz, %User{} = user, question_id, option_id) do
    question = Enum.find(quiz.questions, &(&1.id == question_id))

    cond do
      is_nil(question) or not Enum.any?(question.options, &(&1["id"] == option_id)) ->
        {:error, :unknown}

      not owner?(quiz, user) ->
        {:error, :not_owner}

      true ->
        %Answer{}
        |> Answer.changeset(%{
          question_id: question.id,
          user_id: user.id,
          option_id: option_id,
          correct: right?(question, option_id)
        })
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:question_id, :user_id])
        |> case do
          {:ok, _} -> {:ok, answers_for(quiz, user.id)}
          error -> error
        end
    end
  end

  defp owner?(%Quiz{poet_id: poet_id}, %User{id: user_id}),
    do: Repo.exists?(from p in Poet, where: p.id == ^poet_id and p.user_id == ^user_id)

  def right?(%Question{answer_id: answer_id}, option_id), do: answer_id == option_id

  @doc "`%{right, of, tier}` for a set of answers; `tier` picks the poet's closing note."
  def score(%Quiz{questions: questions}, answers) do
    right = Enum.count(questions, &right?(&1, Map.get(answers, &1.id)))
    of = length(questions)
    %{right: right, of: of, tier: tier(right, of)}
  end

  @doc "high (about 4 in 5 right), mid (half or more), low."
  def tier(right, of) when of > 0 do
    cond do
      right / of >= 0.8 -> "high"
      right / of >= 0.5 -> "mid"
      true -> "low"
    end
  end

  def tier(_right, _of), do: "low"

  @doc "Whether every question has an answer."
  def finished?(%Quiz{questions: questions}, answers),
    do: Enum.all?(questions, &Map.has_key?(answers, &1.id))

  ## The handout

  @doc """
  What the poet may ask about today, chosen by the app:

    * `candidates`: up to #{@candidates} paragraphs from the pages published
      since the last quiz (all pages before the first), at most #{@per_page}
      a page. Paragraphs the reader read through come first, then those on
      pages they opened, then the rest: a quiz on a page they never read is
      a test, not a memory.
    * `drawings`: up to #{@drawings} past main drawings, each with its place.
    * `places`: where the journey has been, for plausible wrong answers.

  Deterministic for a day, so a retried run is handed the same material.
  """
  def handout(%Poet{} = poet, %Date{} = today \\ Date.utc_today()) do
    entries = source_entries(poet.id, today)
    last = facts(poet.id, today).last_quiz_on
    window = if last, do: Enum.filter(entries, &(Date.compare(&1.entry_date, last) == :gt))
    window = if window && length(window) >= 6, do: window, else: entries
    start = Journal.first_published_date(poet.id)

    %{
      candidates: candidates(poet, window, start),
      drawings: drawings(window, start),
      places:
        entries
        |> Enum.map(&place_of/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.take(-30)
    }
  end

  # Published pages before today, oldest first, sections loaded; quiz pages
  # are not material (their story is the quiz's own intro).
  defp source_entries(poet_id, today) do
    quiz_entry_ids =
      from(q in Quiz, where: q.poet_id == ^poet_id and not is_nil(q.journal_entry_id))
      |> select([q], q.journal_entry_id)

    from(e in Entry,
      where: e.poet_id == ^poet_id and e.status == "published" and e.entry_date < ^today,
      where: e.id not in subquery(quiz_entry_ids),
      order_by: [asc: e.entry_date]
    )
    |> Repo.all()
    |> Journal.preload_entries()
  end

  defp candidates(poet, entries, start) do
    reads = reads(poet.user_id, Enum.map(entries, & &1.id))

    entries
    |> Enum.map(fn entry ->
      viewed = (entry.owner_view_count || 0) > 0 or not is_nil(entry.owner_viewed_at)

      entry.sections
      |> Paragraphs.of_sections()
      |> Enum.map(fn p ->
        read = Map.get(reads, {entry.id, p.key})

        score =
          cond do
            read && TravelingPoet.Affinity.read_through?(read) -> 2
            viewed -> 1
            true -> 0
          end

        {score, String.length(p.text), entry, p}
      end)
      |> Enum.sort_by(fn {score, len, _e, _p} -> {-score, -len} end)
      |> Enum.take(@per_page)
    end)
    |> Enum.reject(&(&1 == []))
    |> round_robin()
    |> Enum.take(@candidates)
    |> Enum.sort_by(fn {_s, _l, entry, _p} -> Date.to_gregorian_days(entry.entry_date) end)
    |> Enum.map(fn {score, _len, entry, p} ->
      %{
        key: p.key,
        entry_date: entry.entry_date,
        journey_day: Journal.journey_day(entry.entry_date, start),
        place: place_of(entry),
        read: score == 2,
        text: excerpt(p.text)
      }
    end)
  end

  # Best-read pages first, one paragraph from each before a second from
  # any, so the quiz spans the journey rather than the page they loved most.
  defp round_robin(groups) do
    groups =
      Enum.sort_by(groups, fn [{score, _l, entry, _p} | _] ->
        {-score, -Date.to_gregorian_days(entry.entry_date)}
      end)

    0..(@per_page - 1)
    |> Enum.flat_map(fn i -> Enum.flat_map(groups, &(&1 |> Enum.drop(i) |> Enum.take(1))) end)
  end

  defp reads(_user_id, []), do: %{}

  defp reads(user_id, entry_ids) do
    from(r in ParagraphRead,
      where: r.user_id == ^user_id and r.journal_entry_id in ^entry_ids,
      group_by: [r.journal_entry_id, r.key],
      select: {r.journal_entry_id, r.key, sum(r.ms), max(r.chars)}
    )
    |> Repo.all()
    |> Map.new(fn {entry_id, key, ms, chars} -> {{entry_id, key}, %{ms: ms, chars: chars}} end)
  end

  defp drawings(entries, start) do
    with_drawing =
      entries
      |> Enum.filter(&place_of/1)
      |> Enum.filter(&is_nil(TravelingPoet.Topics.excursion_of(&1)))
      |> Enum.map(&{&1, Journal.entry_illustration(&1)})
      |> Enum.filter(fn {_e, media} -> media end)

    # Spread across the window, not the last few days.
    step = max(div(length(with_drawing), @drawings), 1)

    with_drawing
    |> Enum.take_every(step)
    |> Enum.take(@drawings)
    |> Enum.map(fn {entry, media} ->
      %{
        media_id: media.id,
        entry_date: entry.entry_date,
        journey_day: Journal.journey_day(entry.entry_date, start),
        place: place_of(entry)
      }
    end)
  end

  defp place_of(%Entry{place_name: name}) when is_binary(name) and name != "", do: name

  defp place_of(entry) do
    case TravelingPoet.Topics.excursion_of(entry) do
      %{destination_name: name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp excerpt(text) do
    if String.length(text) > @excerpt_max,
      do:
        String.slice(text, 0, @excerpt_max) |> String.replace(~r/\s+\S*$/u, "") |> Kernel.<>("…"),
      else: text
  end

  ## The poet's quiz

  @doc """
  Puts the poet's quiz on today's entry, replacing any earlier put until
  the reader has answered anything.

  `params`: `"questions"` (#{@min_questions}-#{@max_questions}) and `"notes"`
  (`high`, `mid`, `low`). Returns `{:ok, quiz}`, `{:error, :not_quiz_day}`,
  `{:error, :answered}` or `{:error, {:invalid, [message]}}` naming every
  question that needs fixing.
  """
  def put(%Poet{} = poet, %Entry{} = entry, params) do
    with {:ok, quiz} <- quiz_for_entry(poet, entry),
         :ok <- unanswered(quiz),
         {:ok, notes, questions} <- validate(poet, entry, params) do
      save(quiz, entry, notes, questions)
    end
  end

  defp quiz_for_entry(poet, entry) do
    cond do
      quiz = for_day(poet.id, entry.entry_date) -> {:ok, quiz}
      entry.entry_date == Date.utc_today() and due(poet) -> hold_day(poet, entry.entry_date)
      true -> {:error, :not_quiz_day}
    end
  end

  defp unanswered(%Quiz{id: id}) do
    answered? =
      Repo.exists?(
        from a in Answer,
          join: q in Question,
          on: q.id == a.question_id,
          where: q.quiz_id == ^id
      )

    if answered?, do: {:error, :answered}, else: :ok
  end

  defp save(quiz, entry, notes, questions) do
    Repo.transaction(fn ->
      {:ok, quiz} =
        quiz
        |> Quiz.changeset(%{
          journal_entry_id: entry.id,
          notes: notes,
          status: if(entry.status == "published", do: "published", else: "written")
        })
        |> Repo.update()

      Repo.delete_all(from q in Question, where: q.quiz_id == ^quiz.id)

      questions
      |> Enum.with_index(1)
      |> Enum.each(fn {attrs, position} ->
        {:ok, _} =
          %Question{}
          |> Question.changeset(Map.merge(attrs, %{quiz_id: quiz.id, position: position}))
          |> Repo.insert()
      end)

      Repo.preload(quiz, :questions, force: true)
    end)
  end

  ## Validation

  defp validate(poet, entry, params) do
    known = known_paragraphs(poet.id, entry.entry_date)
    drawings = known_drawings(poet.id, entry.entry_date)
    {notes, note_errors} = validate_notes(params["notes"])

    raw = params["questions"]

    count_errors =
      cond do
        not is_list(raw) ->
          ["questions must be a list of #{@min_questions} to #{@max_questions}"]

        length(raw) < @min_questions or length(raw) > @max_questions ->
          ["send #{@min_questions} to #{@max_questions} questions (you sent #{length(raw)})"]

        true ->
          []
      end

    results =
      if is_list(raw),
        do:
          raw |> Enum.with_index(1) |> Enum.map(fn {q, i} -> question(q, i, known, drawings) end),
        else: []

    question_errors = for {:error, msgs} <- results, msg <- msgs, do: msg

    case note_errors ++ count_errors ++ question_errors do
      [] -> {:ok, notes, for({:ok, q} <- results, do: q)}
      errors -> {:error, {:invalid, errors}}
    end
  end

  defp validate_notes(notes) when is_map(notes) do
    Enum.reduce(Quiz.tiers(), {%{}, []}, fn tier, {acc, errors} ->
      case clean(notes[tier]) do
        nil -> {acc, errors ++ ["notes.#{tier} is required"]}
        text -> {Map.put(acc, tier, cap(text, @note_max)), errors}
      end
    end)
  end

  defp validate_notes(_), do: {%{}, ["notes (high, mid, low) are required"]}

  defp question(q, i, known, drawings) when is_map(q) do
    kind = q["kind"]
    prompt = clean(q["prompt"])
    options = normalize_options(q["options"])

    base_errors =
      [
        kind not in Question.kinds() &&
          "kind must be one of #{Enum.join(Question.kinds(), ", ")}",
        is_nil(prompt) && "prompt is required",
        prompt && String.length(prompt) > @prompt_max &&
          "prompt is over #{@prompt_max} characters",
        Enum.any?(options, &is_nil(&1["text"])) && "every option needs text",
        Enum.any?(options, &(String.length(&1["text"] || "") > @option_max)) &&
          "an option is over #{@option_max} characters",
        length(Enum.uniq_by(options, &String.downcase(&1["text"] || ""))) != length(options) &&
          "two options say the same thing"
      ]
      |> Enum.filter(& &1)

    kind_result =
      if kind in Question.kinds(),
        do: by_kind(kind, q, options, known, drawings),
        else: {:ok, %{}}

    case {base_errors, kind_result} do
      {[], {:ok, attrs}} ->
        {:ok,
         Map.merge(
           %{kind: kind, prompt: prompt, aside: q["aside"] |> clean() |> cap(@aside_max)},
           attrs
         )}

      {errors, {:error, more}} ->
        {:error, Enum.map(errors ++ more, &"question #{i}: #{&1}")}

      {errors, _} ->
        {:error, Enum.map(errors, &"question #{i}: #{&1}")}
    end
  end

  defp question(_q, i, _known, _drawings), do: {:error, ["question #{i}: must be an object"]}

  # Which is true? 3-4 options, the answer a letter, the fact cited.
  defp by_kind("choice", q, options, known, _drawings) do
    with :ok <- option_count(options, 3..4),
         {:ok, answer} <- answer_letter(q["answer"], options),
         {:ok, entry} <- cite(q["source_key"], known) do
      {:ok,
       %{
         options: ids(options),
         answer_id: answer,
         source_key: q["source_key"],
         source_entry_id: entry.id
       }}
    end
  end

  # Two truths and a fib: three statements, the answer the fib; each truth
  # cites the paragraph it came from, the fib cites nothing.
  defp by_kind("fib", q, options, known, _drawings) do
    with :ok <- option_count(options, 3..3),
         {:ok, answer} <- answer_letter(q["answer"], options) do
      options = ids(options)
      {fib, truths} = Enum.split_with(options, &(&1["id"] == answer))

      errors =
        [
          Enum.any?(fib, & &1["source_key"]) &&
            "the fib (the answer) is made up, so it cites no source_key",
          Enum.any?(truths, &(not Map.has_key?(known, &1["source_key"]))) &&
            "each true statement needs the source_key of the paragraph it came from (from travel.quiz.candidates)"
        ]
        |> Enum.filter(& &1)

      if errors == [] do
        options = Enum.map(options, &with_source(&1, known))
        first_truth = Enum.find(options, & &1["source_key"])

        {:ok,
         %{
           options: options,
           answer_id: answer,
           source_key: first_truth["source_key"],
           source_entry_id: first_truth["source_entry_id"]
         }}
      else
        {:error, errors}
      end
    end
  end

  # Where did I draw this? A past drawing from the handout, 3-4 places, and
  # the answer must be the place it was drawn.
  defp by_kind("drawing", q, options, _known, drawings) do
    media_id = to_int(q["media_id"])

    with :ok <- option_count(options, 3..4),
         {:ok, answer} <- answer_letter(q["answer"], options),
         {:ok, entry} <- drawing(media_id, drawings),
         :ok <- same_place(Enum.find(ids(options), &(&1["id"] == answer)), entry) do
      {:ok,
       %{
         options: ids(options),
         answer_id: answer,
         media_id: media_id,
         source_entry_id: entry.id
       }}
    end
  end

  # Which came first? Three moments, each cited, from three different days;
  # the app sets the answer from the dates.
  defp by_kind("first", _q, options, known, _drawings) do
    with :ok <- option_count(options, 3..3) do
      cited = Enum.map(options, &Map.get(known, &1["source_key"]))

      cond do
        Enum.any?(cited, &is_nil/1) ->
          {:error,
           [
             "each moment needs the source_key of the paragraph it came from (from travel.quiz.candidates)"
           ]}

        cited |> Enum.map(& &1.entry_date) |> Enum.uniq() |> length() < 3 ->
          {:error, ["the three moments must come from three different days"]}

        true ->
          options = options |> ids() |> Enum.map(&with_source(&1, known))
          earliest = Enum.min_by(options, &Map.fetch!(known, &1["source_key"]).entry_date, Date)

          {:ok,
           %{
             options: options,
             answer_id: earliest["id"],
             source_key: earliest["source_key"],
             source_entry_id: earliest["source_entry_id"]
           }}
      end
    end
  end

  defp option_count(options, range) do
    if length(options) in range,
      do: :ok,
      else:
        {:error, ["this kind takes #{range_text(range)} options (you sent #{length(options)})"]}
  end

  defp range_text(a..a//_), do: "#{a}"
  defp range_text(a..b//_), do: "#{a} or #{b}"

  defp answer_letter(answer, options) when is_binary(answer) do
    letter = answer |> String.trim() |> String.downcase()
    allowed = Enum.take(@letters, length(options))

    if letter in allowed,
      do: {:ok, letter},
      else:
        {:error, ["answer must be the letter of the right option: #{Enum.join(allowed, ", ")}"]}
  end

  defp answer_letter(_answer, options),
    do:
      {:error,
       [
         "answer must be the letter of the right option: #{Enum.join(Enum.take(@letters, length(options)), ", ")}"
       ]}

  defp cite(key, known) do
    case Map.get(known, key) do
      nil ->
        {:error,
         [
           "source_key must be the key of the paragraph the fact came from (from travel.quiz.candidates)"
         ]}

      entry ->
        {:ok, entry}
    end
  end

  defp drawing(media_id, drawings) do
    case Map.get(drawings, media_id) do
      nil -> {:error, ["media_id must be one of travel.quiz.drawings"]}
      entry -> {:ok, entry}
    end
  end

  # "Sintra" for "Sintra, Portugal" and the other way round.
  defp same_place(%{"text" => text}, %Entry{place_name: place}) do
    a = String.downcase(text)
    b = String.downcase(place)
    city = b |> String.split(",") |> hd() |> String.trim()

    if String.contains?(a, city) or String.contains?(b, String.trim(a)),
      do: :ok,
      else: {:error, ["the right answer must be the place this was drawn: #{place}"]}
  end

  defp same_place(_option, _entry), do: {:error, ["the answer names no option"]}

  defp normalize_options(options) when is_list(options) do
    Enum.map(options, fn
      text when is_binary(text) ->
        %{"text" => clean(text)}

      %{} = o ->
        %{"text" => clean(o["text"]), "source_key" => clean(o["source_key"])}

      _ ->
        %{"text" => nil}
    end)
  end

  defp normalize_options(_), do: []

  defp ids(options) do
    options
    |> Enum.zip(@letters)
    |> Enum.map(fn {o, id} ->
      o |> Map.put("id", id) |> Map.reject(fn {_k, v} -> is_nil(v) end)
    end)
  end

  defp with_source(%{"source_key" => key} = option, known) when is_binary(key) do
    case Map.get(known, key) do
      nil -> option
      entry -> Map.put(option, "source_entry_id", entry.id)
    end
  end

  defp with_source(option, _known), do: option

  # Every paragraph of every page before today, by key: what the poet may
  # cite. Wider than the handout, so a paragraph the reader read between the
  # handout and the put is still citable.
  defp known_paragraphs(poet_id, today) do
    poet_id
    |> source_entries(today)
    |> Enum.flat_map(fn entry ->
      entry.sections |> Paragraphs.of_sections() |> Enum.map(&{&1.key, entry})
    end)
    |> Map.new()
  end

  defp known_drawings(poet_id, today) do
    poet_id
    |> source_entries(today)
    |> Enum.filter(&(is_binary(&1.place_name) and &1.place_name != ""))
    |> Enum.flat_map(fn entry ->
      case Journal.entry_illustration(entry) do
        nil -> []
        media -> [{media.id, entry}]
      end
    end)
    |> Map.new()
  end

  defp clean(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  defp clean(_), do: nil

  defp cap(nil, _max), do: nil
  defp cap(text, max), do: String.slice(text, 0, max)

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
