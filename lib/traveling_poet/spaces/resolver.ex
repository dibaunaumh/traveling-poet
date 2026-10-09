defmodule TravelingPoet.Spaces.Resolver do
  @moduledoc """
  Decides whether a thing a poet just reported is an item we already have
  (kb-002, "entity resolution"). Pure: the caller fetches the candidates,
  this module only compares.

  Rules, in order, for a probe (what was reported) against candidates of the
  same kind:

    1. The same source URL, for things that are a page (a talk, a paper, a
       book): one page, one item. Never for places or events, which cite
       the venue's page.
    2. The same normalised name (`Guide.name_key/1`) in the same city, or
       within a kilometre of each other, or when neither side has a city or
       coordinates to disagree on (a find, a book). Two "Central Market"s in
       two cities stay two items.
    3. Coordinates within 200 m and a name this similar (Jaro >= 0.92):
       "MOCAK" never matches "Museum of Contemporary Art", but "Nishijin
       Textile Centre" matches "Nishijin Textile Center".
    4. Otherwise new. A new item whose name is that similar to one in the
       same city, or contains it ("MOCAK Museum" inside "MOCAK Museum of
       Art"), is also handed back as a review candidate, so an admin can
       merge the pair later.

  A city (a poet's stay) is matched more loosely: the same name, or within
  10 km whatever it was called ("Lisbon" and "Lisboa"), the distance
  `Poets.earlier_stay/2` already calls the same place.

  There is no model call here. kb-002 keeps one behind a flag for the
  ambiguous pairs; phase 0 writes them to `ItemReview` instead.
  """

  alias TravelingPoet.Geo

  @similar 0.92
  @near_km 0.2
  @same_name_km 1.0
  @same_city_km 10.0

  @doc """
  `{:match, item}`, `{:new, review_candidates}`, or `{:series, earlier}` for
  a later edition of an event we already have.

  `probe` is a map with `:norm_name` and optionally `:lat`, `:lng`, `:city`,
  `:source_url`, `:subkind`.
  """
  def decide(probe, candidates) do
    key = probe.norm_name

    cond do
      key == "" ->
        {:new, []}

      item = Enum.find(candidates, &same_url?(probe, &1)) ->
        {:match, item}

      item = Enum.find(candidates, &same_name?(probe, &1)) ->
        if another_edition?(probe, item), do: {:series, item}, else: {:match, item}

      item = Enum.find(candidates, &near_and_similar?(probe, &1)) ->
        {:match, item}

      true ->
        {:new, Enum.filter(candidates, &review_worthy?(probe, &1))}
    end
  end

  @doc """
  A name as a matching key: no accents, case, apostrophes or punctuation,
  in any script. `Guide.name_key/1` keeps only a-z, which turned 京都市
  into nothing and refused the item.
  """
  def name_key(name) when is_binary(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/['\x{2019}\x{2018}`]/u, "")
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  def name_key(_), do: ""

  # This year's festival is not last year's: an event with the same name
  # whose dates sit clear of the known edition's is a new item, linked
  # series_of the earlier one. Unknown dates on either side mean one event.
  @edition_gap_days 30

  defp another_edition?(%{kind: "event"} = probe, %{time_start: %Date{} = start} = item) do
    case Map.get(probe, :time_start) do
      %Date{} = probe_start ->
        probe_end = Map.get(probe, :time_end) || probe_start
        item_end = item.time_end || start

        Date.diff(probe_start, item_end) > @edition_gap_days or
          Date.diff(start, probe_end) > @edition_gap_days

      _ ->
        false
    end
  end

  defp another_edition?(_probe, _item), do: false

  @doc "A URL stripped to what identifies the page: no scheme, www, query or trailing slash."
  def url_key(nil), do: nil

  def url_key(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/^https?:\/\/(www\.)?/, "")
    |> String.replace(~r/[?#].*$/, "")
    |> String.trim_trailing("/")
    |> case do
      "" -> nil
      key -> key
    end
  end

  def url_key(_), do: nil

  @doc "The city, as a matching key."
  def city_key(city), do: name_key(city)

  @doc "Name similarity on the normalised names, 0..1."
  def similarity(a, b) when is_binary(a) and is_binary(b), do: String.jaro_distance(a, b)
  def similarity(_, _), do: 0.0

  # Only for things that ARE a page (a talk, a paper, a book). Two events
  # at one museum cite the museum's page: on the prod copy "Zen and Ghibli
  # Exhibition" merged into "Kyoto City KYOCERA Museum of Art" that way.
  @page_kinds ~w(idea work product other)

  defp same_url?(%{kind: kind, source_url: url}, %{source_url: other})
       when kind in @page_kinds and is_binary(url) do
    key = url_key(url)
    not is_nil(key) and key == url_key(other)
  end

  defp same_url?(_, _), do: false

  defp same_name?(probe, item) do
    probe.norm_name == item.norm_name and
      (city?(probe, item) or within?(probe, item, same_name_km(probe)) or
         placeless?(probe, item))
  end

  # The same name, and nothing to say they are not the same thing: a find
  # has no city or pin, a place whose entry carried no city neither.
  defp placeless?(probe, item) do
    is_nil(coords(probe)) and is_nil(coords(item)) and
      (blank?(Map.get(probe, :city)) or blank?(item.city))
  end

  defp near_and_similar?(%{subkind: "city"} = probe, item),
    do: within?(probe, item, @same_city_km)

  defp near_and_similar?(probe, item) do
    within?(probe, item, @near_km) and
      similarity(probe.norm_name, item.norm_name) >= @similar
  end

  defp review_worthy?(probe, item) do
    city?(probe, item) and
      (similarity(probe.norm_name, item.norm_name) >= @similar or
         (contains?(probe.norm_name, item.norm_name) and not neighbourhood?(probe, item)))
  end

  # A place inside a neighbourhood carries its name ("Fremont Troll" in
  # "Fremont"); that is containment, not a duplicate. On the prod copy 17
  # of 29 review rows were this.
  defp neighbourhood?(probe, item),
    do: Map.get(probe, :subkind) == "neighbourhood" or item.subkind == "neighbourhood"

  # One name inside the other, both long enough to mean something.
  defp contains?(a, b) do
    min(String.length(a), String.length(b)) >= 6 and
      (String.contains?(a, b) or String.contains?(b, a))
  end

  defp city?(probe, item) do
    a = city_key(Map.get(probe, :city))
    b = city_key(item.city)
    a != "" and a == b
  end

  defp within?(probe, item, km) do
    case {coords(probe), coords(item)} do
      {{lat1, lng1}, {lat2, lng2}} -> Geo.distance_km(lat1, lng1, lat2, lng2) <= km
      _ -> false
    end
  end

  defp coords(%{lat: lat, lng: lng}) when is_number(lat) and is_number(lng), do: {lat, lng}
  defp coords(_), do: nil

  defp same_name_km(%{subkind: "city"}), do: @same_city_km
  defp same_name_km(_), do: @same_name_km

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_), do: true
end
