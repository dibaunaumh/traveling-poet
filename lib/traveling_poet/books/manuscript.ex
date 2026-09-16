defmodule TravelingPoet.Books.Manuscript do
  @moduledoc """
  A whole journey laid out as a book, before any page is drawn.

  Pure: takes the poet, every published day as an `EntryBundle`, and the
  poet's path, and returns chapters of days. A chapter is a stay (one path
  point): the book reads as the journey did, city by city, with the days in
  order inside each. Excursion days fall into the stay they happened in,
  because the poet did not leave town to take one. A poet with no path at
  all gets one chapter named after wherever it first wrote from.

  Nothing here touches the stored entries; the renderer reads the bundles
  the pages already read.
  """

  alias TravelingPoet.Books.{Index, Sources, Urls}
  alias TravelingPoet.{Guide, Journal}

  defmodule Day do
    @moduledoc false
    defstruct [:number, :date, :entry, :bundle, :url, :anchor, :sources, :stay_id]
  end

  defmodule Chapter do
    @moduledoc false
    defstruct [:number, :stay, :title, :from, :to, :anchor, days: [], places: [], finds: []]
  end

  defstruct poet: nil,
            title: nil,
            subtitle: nil,
            journey_start: nil,
            from: nil,
            to: nil,
            entry_count: 0,
            chapters: [],
            index: %{},
            colophon: %{}

  @type t :: %__MODULE__{}

  @doc """
  Options: `now:` (the generated-at stamp), `edition:` ("plain" | "composed"),
  `title:` to override the cover title.
  """
  @spec build(map, [map], [map], keyword) :: t
  def build(poet, bundles, stays, opts \\ []) do
    bundles =
      bundles
      |> Enum.reject(&is_nil(&1.entry))
      |> Enum.sort_by(& &1.entry.entry_date, Date)

    start = bundles |> List.first() |> then(&(&1 && &1.entry.entry_date))
    finish = bundles |> List.last() |> then(&(&1 && &1.entry.entry_date))

    days = Enum.map(bundles, &day(poet, &1, start, stays))
    chapters = chapters(days, stays)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    %__MODULE__{
      poet: poet,
      title: Keyword.get(opts, :title) || poet.name,
      subtitle: subtitle(start, finish),
      journey_start: start,
      from: start,
      to: finish,
      entry_count: length(days),
      chapters: chapters,
      index: Index.build(chapters, poet),
      colophon: %{
        poet_name: poet.name,
        from: start,
        to: finish,
        entry_count: length(days),
        chapter_count: length(chapters),
        generated_at: now,
        edition: Keyword.get(opts, :edition, "plain"),
        site_url: site_url(),
        journal_url: Urls.journal_url(poet)
      }
    }
  end

  @doc "The anchor id of a day's page, shared by the TOC and the index."
  def day_anchor(%Date{} = date), do: "day-#{Date.to_iso8601(date)}"

  @doc "The anchor id of a chapter's opening page."
  def chapter_anchor(n) when is_integer(n), do: "chapter-#{n}"

  @doc """
  A chapter's stable name for matter written about it: the stay's id, which
  survives the journey growing (chapter numbers shift when a day lands
  outside every stay), or "unplaced" for the days that belong to none.
  """
  def chapter_key(%{stay: %{id: id}}) when is_integer(id), do: Integer.to_string(id)
  def chapter_key(_chapter), do: "unplaced"

  defp day(poet, bundle, start, stays) do
    entry = bundle.entry

    %Day{
      number: Journal.journey_day(entry.entry_date, start),
      date: entry.entry_date,
      entry: entry,
      bundle: bundle,
      url: Urls.entry_url(poet, entry),
      anchor: day_anchor(entry.entry_date),
      sources: Sources.for_bundle(bundle),
      stay_id: bundle.stay_id || Guide.path_point_for(entry, stays)
    }
  end

  # Chapters follow the path in position order and only stays with days
  # become chapters (a five-minute onboarding stop the poet never wrote from
  # is not a chapter). Days outside every stay come first, as one chapter.
  defp chapters(days, stays) do
    by_stay = Enum.group_by(days, & &1.stay_id)

    orphan =
      case Map.get(by_stay, nil, []) do
        [] -> []
        orphans -> [{nil, orphans}]
      end

    placed =
      stays
      |> Enum.sort_by(& &1.position)
      |> Enum.flat_map(fn stay ->
        case Map.get(by_stay, stay.id, []) do
          [] -> []
          chapter_days -> [{stay, chapter_days}]
        end
      end)

    (orphan ++ placed)
    |> Enum.with_index(1)
    |> Enum.map(fn {{stay, chapter_days}, n} -> chapter(n, stay, chapter_days) end)
  end

  defp chapter(n, stay, days) do
    first = hd(days)
    stay = stay || %{id: nil, place_name: first.entry.place_name, country_code: nil}

    %Chapter{
      number: n,
      stay: stay,
      title: stay.place_name || "On the road",
      from: first.date,
      to: List.last(days).date,
      anchor: chapter_anchor(n),
      days: days,
      places: days |> Enum.flat_map(& &1.bundle.places) |> Enum.uniq_by(&name_key(&1.name)),
      finds: days |> Enum.flat_map(& &1.bundle.finds) |> Enum.uniq_by(&name_key(&1.name))
    }
  end

  defp name_key(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp name_key(other), do: other

  defp subtitle(nil, _finish), do: "A Traveling Poet's journal"

  defp subtitle(start, finish),
    do: "A Traveling Poet's journal, #{season(start)} to #{season(finish)}"

  defp season(%Date{} = d), do: "#{Calendar.strftime(d, "%B %Y")}"

  defp site_url do
    case Urls.base() do
      "" -> "https://poet.travel"
      base -> base
    end
  end
end
