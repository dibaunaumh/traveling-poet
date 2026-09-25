defmodule TravelingPoet.Affinity do
  @moduledoc """
  The reader's taste profile (card-49): which subjects on the subject tree
  (`Guide.PlaceTopics`) they have an affinity for, learned from how they
  treat their own journal. Owner only: every signal is the owner's, on their
  own poet's pages.

  The subject tree is the coordinate system (card-37): places, finds, topics,
  tastes and paragraphs all sit on it, so a profile is a set of
  `{path, score}` pairs, for or against.

  Signals, each spread over the subjects of what it touched:
  - a topic or taste the reader keeps (active or paused), +4, and it does
    not fade: it stands until they remove it;
  - a feedback marker, ±3 (`@marker_polarity`: "Interesting" is for, "Boring"
    against; the kinds about the writing, not the subject, count for nothing),
    on the paragraph(s) it marks;
  - a reaction to a page, ±2, over the page's subjects (`PageSubjects`);
  - reading a paragraph through, +1 (a day's time on it at least half what
    reading it takes at #{17} characters a second); a skim or a skip is 0.
    Only while `users.reading_signals` is on.

  A paragraph's first subject takes two thirds of its signal, its second a
  third. Every signal halves in weight every 30 days, so the profile follows
  the reader as they change. Nothing is stored but the reader's dismissals:
  the profile is computed from the signals whenever it is asked for.
  """

  import Ecto.Query

  alias TravelingPoet.{Poets, Repo}
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Affinity.Dismissal
  alias TravelingPoet.Guide.PlaceTopics
  alias TravelingPoet.Journal.{Entry, Marker, PageSubjects, Paragraphs, ParagraphSubject}
  alias TravelingPoet.Journal.{Reaction, Section}
  alias TravelingPoet.Reading.ParagraphRead
  alias TravelingPoet.Topics.Topic

  @half_life_days 30
  @topic_weight 4
  @marker_weight 3
  @reaction_weight 2
  @read_weight 1
  @chars_per_second 17
  @read_through 0.5

  @marker_polarity %{
    "interesting" => 1,
    "beautiful" => 1,
    "more_details" => 1,
    "drawing_needed" => 1,
    "link_needed" => 1,
    "boring" => -1
  }
  @reaction_polarity %{"love" => 1, "inspiring" => 1, "want_more" => 1, "not_for_me" => -1}

  # What it takes to show a subject: about two paragraphs read through, or
  # one marker, recently.
  @min_score 1.5

  @doc """
  The profile: `[%{path, names, score}]`, highest first, dismissed subjects
  left out. `names` are the path's names on the tree.
  """
  def profile(%User{} = user, now \\ DateTime.utc_now()) do
    dismissed = MapSet.new(dismissed_paths(user))

    user
    |> signals()
    |> score(now)
    |> Enum.reject(fn {path, _} -> MapSet.member?(dismissed, path) end)
    |> Enum.map(fn {path, score} ->
      %{path: path, names: PlaceTopics.names(path), score: score}
    end)
    |> Enum.filter(& &1.names)
  end

  @doc "The subjects to show as the reader's: positive and above the bar, at most `n`."
  def top(%User{} = user, n \\ 8, now \\ DateTime.utc_now()) do
    user |> profile(now) |> Enum.filter(&(&1.score >= @min_score)) |> Enum.take(n)
  end

  @doc """
  Pure: signals (`%{at: Date | DateTime | :now, weight, subjects: [{path, share}]}`)
  to `[{path, score}]`, highest first, each signal decayed by its age.
  """
  def score(signals, now \\ DateTime.utc_now()) do
    today = to_date(now)

    signals
    |> Enum.flat_map(fn s ->
      w = if s.at == :now, do: s.weight, else: s.weight * decay(Date.diff(today, to_date(s.at)))
      Enum.map(s.subjects, fn {path, share} -> {path, w * share} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {path, ws} -> {path, Float.round(Enum.sum(ws), 3)} end)
    |> Enum.sort_by(fn {path, s} -> {-s, path} end)
  end

  defp decay(age_days), do: :math.pow(0.5, max(age_days, 0) / @half_life_days)

  defp to_date(%DateTime{} = t), do: DateTime.to_date(t)
  defp to_date(%NaiveDateTime{} = t), do: NaiveDateTime.to_date(t)
  defp to_date(%Date{} = d), do: d

  @doc "Takes a subject off the reader's profile, for good."
  def dismiss(%User{id: user_id}, path) when is_binary(path) do
    %Dismissal{}
    |> Dismissal.changeset(%{user_id: user_id, path: path})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :path])
  end

  @doc "Puts a dismissed subject back."
  def restore(%User{id: user_id}, path) do
    Repo.delete_all(from d in Dismissal, where: d.user_id == ^user_id and d.path == ^path)
    :ok
  end

  @doc "Dismissed subjects as `[%{path, names}]`, newest first."
  def dismissed(%User{} = user) do
    user
    |> dismissed_paths()
    |> Enum.map(&%{path: &1, names: PlaceTopics.names(&1)})
    |> Enum.filter(& &1.names)
  end

  defp dismissed_paths(%User{id: user_id}) do
    Repo.all(
      from d in Dismissal,
        where: d.user_id == ^user_id,
        order_by: [desc: d.inserted_at, desc: d.id],
        select: d.path
    )
  end

  @doc "Every signal the reader has left on their own journal."
  def signals(%User{} = user) do
    case Poets.get_poet_by_user(user.id) do
      nil ->
        []

      poet ->
        entry_ids = Repo.all(from e in Entry, where: e.poet_id == ^poet.id, select: e.id)
        subjects = paragraph_subjects(poet.id)

        topic_signals(poet.id) ++
          read_signals(user, subjects) ++
          marker_signals(user, entry_ids, subjects) ++ reaction_signals(user, entry_ids)
    end
  end

  # Dated today, so they never decay: what the reader said they follow is
  # true until they take it back.
  defp topic_signals(poet_id) do
    from(t in Topic,
      where: t.poet_id == ^poet_id and t.status in ["active", "paused"] and not is_nil(t.subject),
      select: {t.subject, t.second_subject}
    )
    |> Repo.all()
    |> Enum.map(fn {first, second} ->
      %{at: :now, weight: @topic_weight, subjects: shares(first, second)}
    end)
  end

  defp shares(first, nil), do: [{first, 1.0}]
  defp shares(first, second), do: [{first, 2 / 3}, {second, 1 / 3}]

  # %{{entry_id, key} => [{path, share}]}
  defp paragraph_subjects(poet_id) do
    from(p in ParagraphSubject,
      where: p.poet_id == ^poet_id and not is_nil(p.topic),
      select: {p.journal_entry_id, p.key, p.topic, p.second_topic}
    )
    |> Repo.all()
    |> Map.new(fn {entry_id, key, first, second} -> {{entry_id, key}, shares(first, second)} end)
  end

  defp read_signals(%User{reading_signals: false}, _subjects), do: []

  defp read_signals(%User{id: user_id}, subjects) do
    from(r in ParagraphRead, where: r.user_id == ^user_id)
    |> Repo.all()
    |> Enum.filter(&read_through?/1)
    |> Enum.flat_map(fn r ->
      case Map.get(subjects, {r.journal_entry_id, r.key}) do
        nil -> []
        shares -> [%{at: r.read_on, weight: @read_weight, subjects: shares}]
      end
    end)
  end

  @doc false
  def read_through?(%{ms: ms, chars: chars}),
    do: ms >= @read_through * chars / @chars_per_second * 1000

  defp marker_signals(_user, [], _subjects), do: []

  defp marker_signals(%User{id: user_id}, entry_ids, subjects) do
    markers =
      Repo.all(
        from m in Marker,
          where:
            m.user_id == ^user_id and m.journal_entry_id in ^entry_ids and
              m.kind in ^Map.keys(@marker_polarity) and m.target in ["text", "section"]
      )

    paragraphs = paragraphs_of(Enum.map(markers, & &1.journal_entry_id))

    Enum.flat_map(markers, fn m ->
      keys =
        m |> marked_paragraphs(Map.get(paragraphs, m.journal_entry_id, [])) |> Enum.map(& &1.key)

      shares =
        keys |> Enum.flat_map(&Map.get(subjects, {m.journal_entry_id, &1}, [])) |> normalize()

      if shares == [],
        do: [],
        else: [
          %{
            at: m.inserted_at,
            weight: @marker_weight * Map.fetch!(@marker_polarity, m.kind),
            subjects: shares
          }
        ]
    end)
  end

  # %{entry_id => [%{key, text, section_kind}]}
  defp paragraphs_of([]), do: %{}

  defp paragraphs_of(entry_ids) do
    from(s in Section, where: s.journal_entry_id in ^Enum.uniq(entry_ids))
    |> Repo.all()
    |> Enum.group_by(& &1.journal_entry_id)
    |> Map.new(fn {id, sections} -> {id, Paragraphs.of_sections(sections)} end)
  end

  @doc false
  # A whole-section marker covers the section's paragraphs; a text marker the
  # paragraph(s) its quote is in (a selection can run across several).
  def marked_paragraphs(%{target: "section", section_kind: kind}, paragraphs),
    do: Enum.filter(paragraphs, &(&1.section_kind == kind))

  def marked_paragraphs(%{target: "text", quote: quote}, paragraphs) when is_binary(quote) do
    q = quote |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(q) < 3 do
      []
    else
      Enum.filter(paragraphs, &(String.contains?(&1.text, q) or String.contains?(q, &1.text)))
    end
  end

  def marked_paragraphs(_marker, _paragraphs), do: []

  defp normalize([]), do: []

  defp normalize(shares) do
    total = shares |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    shares
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {path, ws} -> {path, Enum.sum(ws) / total} end)
  end

  defp reaction_signals(_user, []), do: []

  defp reaction_signals(%User{id: user_id}, entry_ids) do
    Repo.all(
      from r in Reaction,
        where:
          r.user_id == ^user_id and r.journal_entry_id in ^entry_ids and
            r.kind in ^Map.keys(@reaction_polarity)
    )
    |> Enum.flat_map(fn r ->
      case PageSubjects.of_entry(r.journal_entry_id) do
        [] ->
          []

        subjects ->
          [
            %{
              at: r.inserted_at,
              weight: @reaction_weight * Map.fetch!(@reaction_polarity, r.kind),
              subjects: Enum.map(subjects, &{&1.path, &1.share})
            }
          ]
      end
    end)
  end
end
