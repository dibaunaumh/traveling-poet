defmodule TravelingPoet.Guide.TopicTagging do
  @moduledoc """
  Puts places into the topic tree (`Guide.PlaceTopics`) and keeps them there.

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

  and `backfill(commit: true)` once the dry run reads right.

      %{places: n, classified: n, untagged: [name], by_top: %{"Art" => n},
        by_topic: %{path => n}, samples: %{path => [name]}}
  """
  def backfill(opts \\ []) do
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
