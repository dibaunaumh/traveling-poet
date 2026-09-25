defmodule TravelingPoet.Guide.TopicTagging do
  @moduledoc """
  Puts places, excursion finds and a reader's topics and tastes into the
  subject tree (`Guide.PlaceTopics`) and keeps them there: one set of
  coordinates for all three. Finds and topics are classified with the
  classifier's `:things` instructions, places with its place ones.

    * New places: `tag_entry_async/1`, called after a poet saves an entry's
      places, classifies the ones not yet classified, in the background, so the
      poet's tool call never waits on it. Places re-sent under the same name
      keep their topics (`Guide.replace_places/2`), so a re-put costs nothing.
    * Existing places: `backfill/1`, callable over `rpc` in prod. A dry run by
      default: it classifies and reports, and writes nothing.

  Off unless `:classify_places` is set (runtime.exs turns it on when an
  OpenRouter key is present, and pins it off in test).
  """

  require Logger
  import Ecto.Query

  alias TravelingPoet.Guide.{Place, PlaceClassifier, PlaceTopics}
  alias TravelingPoet.Journal.Entry
  alias TravelingPoet.Topics.{Excursion, Find, Topic}
  alias TravelingPoet.Journal.{ParagraphSubject, Paragraphs, Section}
  alias TravelingPoet.Repo

  @batch 20

  def enabled?, do: Application.get_env(:traveling_poet, :classify_places, false) == true

  @doc "Classifies an entry's unclassified places in the background. A no-op when off."
  def tag_entry_async(entry_id) do
    if enabled?() do
      Task.start(fn -> tag_entry(entry_id) end)
    else
      :disabled
    end
  end

  @doc "Classifies an entry's unclassified places now. Returns how many were classified."
  def tag_entry(entry_id, opts \\ []) do
    Place
    |> where(journal_entry_id: ^entry_id)
    |> where([p], is_nil(p.topics_classified_at))
    |> Repo.all()
    |> classify_and_save(opts)
  end

  @doc "Classifies an excursion entry's unclassified finds in the background."
  def tag_finds_async(entry_id) do
    if enabled?(), do: Task.start(fn -> tag_finds(entry_id) end), else: :disabled
  end

  @doc "Classifies an entry's unclassified finds now. Returns how many."
  def tag_finds(entry_id, opts \\ []) do
    Find
    |> where(journal_entry_id: ^entry_id)
    |> where([f], is_nil(f.topics_classified_at))
    |> Repo.all()
    |> classify_things(&find_row/1, &save_find/2, opts)
  end

  @doc "Classifies a topic or taste in the background, once per wording."
  def tag_topic_async(%Topic{subjects_classified_at: nil, id: id}) do
    if enabled?(), do: Task.start(fn -> tag_topic(id) end), else: :disabled
  end

  def tag_topic_async(_topic), do: :already

  @doc "Classifies one topic or taste now."
  def tag_topic(topic_id, opts \\ []) do
    Topic
    |> where(id: ^topic_id)
    |> where([t], is_nil(t.subjects_classified_at))
    |> Repo.all()
    |> classify_things(&topic_row/1, &save_topic/2, opts)
  end

  @doc """
  Puts a published entry's paragraphs on the subject tree, in the background:
  only paragraphs whose words are new (a revision's untouched paragraphs
  keep their row, `Journal.Paragraphs`). Called on every publish.
  """
  def tag_paragraphs_async(entry_id) do
    if enabled?(), do: Task.start(fn -> tag_paragraphs(entry_id) end), else: :disabled
  end

  @doc "Classifies an entry's new paragraphs now. Returns how many were saved."
  def tag_paragraphs(entry_id, opts \\ []) do
    case Repo.get(Entry, entry_id) do
      %Entry{status: "published"} = entry ->
        {saved, _seen} =
          classify_paragraphs(entry, fresh_paragraphs(entry), Keyword.put(opts, :commit, true))

        saved

      _ ->
        0
    end
  end

  defp fresh_paragraphs(entry) do
    known =
      ParagraphSubject
      |> where(journal_entry_id: ^entry.id)
      |> select([p], p.key)
      |> Repo.all()
      |> MapSet.new()

    Section
    |> where(journal_entry_id: ^entry.id)
    |> Repo.all()
    |> Paragraphs.of_sections()
    |> Enum.reject(&MapSet.member?(known, &1.key))
  end

  # Paragraphs are not rows until classified: numbered for the model, then
  # written (commit) or only reported. Returns {saved, [{%{name}, verdict}]}.
  defp classify_paragraphs(entry, paragraphs, opts) do
    context = paragraph_context(entry)

    paragraphs
    |> Enum.with_index(1)
    |> Enum.chunk_every(@batch)
    |> Enum.reduce({0, []}, fn batch, {saved, seen} ->
      rows =
        Enum.map(batch, fn {p, i} ->
          %{
            id: i,
            name: String.slice(p.text, 0, 400),
            category: "journal paragraph",
            context: context
          }
        end)

      case PlaceClassifier.classify(rows, Keyword.put(opts, :as, :things)) do
        {:ok, verdicts} ->
          answered = Enum.filter(batch, fn {_p, i} -> verdicts[i] end)

          if opts[:commit],
            do: Enum.each(answered, fn {p, i} -> save_paragraph(entry, p, verdicts[i]) end)

          {saved + length(answered),
           seen ++
             Enum.map(answered, fn {p, i} ->
               {%{name: String.slice(p.text, 0, 80)}, verdicts[i]}
             end)}

        {:error, reason} ->
          Logger.warning("TopicTagging: #{length(batch)} paragraphs failed: #{inspect(reason)}")
          {saved, seen}
      end
    end)
  end

  defp paragraph_context(%Entry{} = entry) do
    label =
      Repo.one(
        from x in Excursion,
          join: t in Topic,
          on: t.id == x.topic_id,
          where: x.journal_entry_id == ^entry.id,
          select: t.label
      )

    if label,
      do: "from a journal page written on a day spent on #{label}",
      else: "from a journal page written in #{entry.place_name || "a place on the road"}"
  end

  defp save_paragraph(entry, p, verdict) do
    %ParagraphSubject{}
    |> ParagraphSubject.changeset(%{
      poet_id: entry.poet_id,
      journal_entry_id: entry.id,
      key: p.key,
      section_kind: p.section_kind,
      excerpt: String.slice(p.text, 0, 160),
      topic: verdict.topic,
      second_topic: verdict.second_topic,
      classified_at: now()
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:journal_entry_id, :key])
  end

  defp classify_things(items, row_fun, save_fun, opts) do
    items
    |> Enum.chunk_every(@batch)
    |> Enum.reduce(0, fn batch, count ->
      case PlaceClassifier.classify(Enum.map(batch, row_fun), Keyword.put(opts, :as, :things)) do
        {:ok, verdicts} ->
          count + Enum.count(batch, &(verdicts[&1.id] && save_fun.(&1, verdicts[&1.id])))

        {:error, reason} ->
          Logger.warning("TopicTagging: #{length(batch)} things failed: #{inspect(reason)}")
          count
      end
    end)
  end

  defp save_find(find, verdict) do
    find
    |> Find.topics_changeset(%{
      topic: verdict.topic,
      second_topic: verdict.second_topic,
      topics_classified_at: now()
    })
    |> adopt_kind(find, verdict.place_type)
    |> Repo.update!()
  end

  # A find the poet could only call "other" takes the classifier's kind, so
  # the village says "Exhibition" or "Film or series", not "Other". A kind
  # the poet chose is never overridden.
  defp adopt_kind(changeset, %Find{kind: "other"}, kind) when kind not in [nil, "other"],
    do: Ecto.Changeset.put_change(changeset, :kind, kind)

  defp adopt_kind(changeset, _find, _kind), do: changeset

  defp save_topic(topic, verdict) do
    topic
    |> Topic.subjects_changeset(%{
      subject: verdict.topic,
      second_subject: verdict.second_topic,
      subjects_classified_at: now()
    })
    |> Repo.update!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # What the excursion was about helps: "Atlas Fractured" alone says little.
  defp find_row(%Find{} = f) do
    context =
      Excursion
      |> where(journal_entry_id: ^f.journal_entry_id)
      |> join(:inner, [x], t in Topic, on: t.id == x.topic_id)
      |> select([x, t], {t.label, t.domain, x.destination_name})
      |> Repo.one()
      |> case do
        {label, nil, dest} ->
          "found on a day spent on #{label}#{dest && " at " <> dest}"

        {label, domain, dest} ->
          "found for a reader's taste in #{domain}: #{label}#{dest && " at " <> dest}"

        nil ->
          nil
      end

    %{id: f.id, name: f.name, category: f.kind, blurb: f.blurb, context: context}
  end

  defp topic_row(%Topic{domain: nil} = t),
    do: %{id: t.id, name: t.label, category: "a subject a reader follows"}

  defp topic_row(%Topic{} = t),
    do: %{id: t.id, name: t.label, category: "a reader's taste in #{t.domain}"}

  @doc """
  Classifies places and writes each verdict, `@batch` places per model call.
  A batch that fails is logged and left unclassified for the next run; one
  bad batch never stops the rest. Returns how many places were classified.
  """
  def classify_and_save(places, opts \\ []) do
    places
    |> Repo.preload(:journal_entry)
    |> Enum.chunk_every(@batch)
    |> Enum.reduce(0, fn batch, count ->
      case PlaceClassifier.classify(Enum.map(batch, &prompt_row/1), opts) do
        {:ok, verdicts} ->
          count + save(batch, verdicts)

        {:error, reason} ->
          Logger.warning("TopicTagging: a batch of #{length(batch)} failed: #{inspect(reason)}")
          count
      end
    end)
  end

  defp save(batch, verdicts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.count(batch, fn place ->
      case Map.get(verdicts, place.id) do
        nil ->
          false

        verdict ->
          place
          |> Place.topics_changeset(Map.put(verdict, :topics_classified_at, now))
          |> Repo.update!()

          true
      end
    end)
  end

  defp prompt_row(%Place{} = p) do
    city =
      case p.journal_entry do
        %Entry{place_name: name} -> name
        _ -> nil
      end

    %{
      id: p.id,
      name: p.name,
      category: p.category,
      blurb: p.blurb,
      address: p.address,
      city: city
    }
  end

  @doc """
  The one-off pass over places that predate the tree.

  Dry run by default: classifies every unclassified place (or `limit:` of
  them), writes nothing, and returns a report. `commit: true` writes. Safe
  to run twice: a classified place is never sent again.

  In production (no Mix; `rpc`, not `eval`):

      fly ssh console -c fly.dev.toml -C "/app/bin/traveling_poet rpc 'TravelingPoet.Guide.TopicTagging.backfill()|>IO.inspect(limit::infinity)'"

  and `backfill(commit: true)` once the dry run reads right. `target:
  :finds` and `target: :topics` do the same for excursion finds and for
  readers' topics and tastes, e.g. `backfill([{:target,:finds}])`.

      %{places: n, classified: n, untagged: [name], by_top: %{"Art" => n},
        by_topic: %{path => n}, samples: %{path => [name]}}
  """
  def backfill(opts \\ [])

  def backfill(opts) when is_list(opts) do
    case Keyword.get(opts, :target, :places) do
      :places ->
        backfill_places(opts)

      :finds ->
        backfill_things(Find, :topics_classified_at, &find_row/1, &save_find/2, opts)

      :topics ->
        backfill_things(Topic, :subjects_classified_at, &topic_row/1, &save_topic/2, opts)

      :paragraphs ->
        backfill_paragraphs(opts)
    end
  end

  # Every published entry's paragraphs not yet classified; `limit:` counts
  # entries, newest first. Dry run unless commit: true.
  defp backfill_paragraphs(opts) do
    commit = Keyword.get(opts, :commit, false)

    Entry
    |> where(status: "published")
    |> order_by(desc: :entry_date)
    |> then(&if(opts[:limit], do: limit(&1, ^opts[:limit]), else: &1))
    |> Repo.all()
    |> Enum.reduce({[], []}, fn entry, {ps, vs} ->
      fresh = fresh_paragraphs(entry)
      {_saved, seen} = classify_paragraphs(entry, fresh, Keyword.put(opts, :commit, commit))
      {ps ++ Enum.map(fresh, &%{name: String.slice(&1.text, 0, 80)}), vs ++ seen}
    end)
    |> then(fn {paragraphs, verdicts} -> report(paragraphs, verdicts, commit) end)
  end

  # Finds and topics: the same dry run and report as places, with the
  # :things instructions. `name` in the report is the find's name or the
  # topic's label.
  defp backfill_things(schema, stamp, row_fun, save_fun, opts) do
    commit = Keyword.get(opts, :commit, false)

    items =
      schema
      |> where([x], is_nil(field(x, ^stamp)))
      |> order_by(asc: :id)
      |> then(&if(opts[:limit], do: limit(&1, ^opts[:limit]), else: &1))
      |> Repo.all()

    verdicts =
      items
      |> Enum.chunk_every(@batch)
      |> Enum.flat_map(fn batch ->
        case PlaceClassifier.classify(Enum.map(batch, row_fun), Keyword.put(opts, :as, :things)) do
          {:ok, verdicts} ->
            if commit, do: Enum.each(batch, &(verdicts[&1.id] && save_fun.(&1, verdicts[&1.id])))
            Enum.flat_map(batch, &List.wrap(verdicts[&1.id] && {named(&1), verdicts[&1.id]}))

          {:error, reason} ->
            Logger.warning("TopicTagging.backfill: a batch failed: #{inspect(reason)}")
            []
        end
      end)

    report(Enum.map(items, &named/1), verdicts, commit)
  end

  defp named(%Topic{label: label}), do: %{name: label}
  defp named(%{name: name}), do: %{name: name}

  defp backfill_places(opts) do
    commit = Keyword.get(opts, :commit, false)

    places =
      Place
      |> where([p], is_nil(p.topics_classified_at))
      |> order_by(asc: :id)
      |> then(&if(opts[:limit], do: limit(&1, ^opts[:limit]), else: &1))
      |> Repo.all()
      |> Repo.preload(:journal_entry)

    verdicts =
      places
      |> Enum.chunk_every(@batch)
      |> Enum.flat_map(fn batch ->
        case PlaceClassifier.classify(Enum.map(batch, &prompt_row/1), opts) do
          {:ok, verdicts} ->
            if commit, do: save(batch, verdicts)
            Enum.flat_map(batch, &List.wrap(verdicts[&1.id] && {&1, verdicts[&1.id]}))

          {:error, reason} ->
            Logger.warning("TopicTagging.backfill: a batch failed: #{inspect(reason)}")
            []
        end
      end)

    report(places, verdicts, commit)
  end

  @doc false
  def report(places, verdicts, commit) do
    tagged = Enum.filter(verdicts, fn {_p, v} -> v.topic end)

    by_topic =
      tagged
      |> Enum.flat_map(fn {p, v} ->
        Enum.reject([{v.topic, p}, {v.second_topic, p}], &is_nil(elem(&1, 0)))
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1).name)

    %{
      committed: commit,
      places: length(places),
      classified: length(verdicts),
      untagged: for({p, %{topic: nil}} <- verdicts, do: p.name),
      by_top:
        by_topic
        |> Enum.group_by(fn {path, _} -> hd(PlaceTopics.names(path)) end, fn {_, names} ->
          length(names)
        end)
        |> Map.new(fn {top, counts} -> {top, Enum.sum(counts)} end),
      by_topic: Map.new(by_topic, fn {path, names} -> {path, length(names)} end),
      samples:
        Map.new(by_topic, fn {path, names} -> {path, names |> Enum.uniq() |> Enum.take(4)} end),
      types: verdicts |> Enum.map(fn {_p, v} -> v.place_type end) |> Enum.frequencies()
    }
  end
end
