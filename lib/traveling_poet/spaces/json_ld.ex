defmodule TravelingPoet.Spaces.JsonLd do
  @moduledoc """
  An item as schema.org JSON-LD (kb-002 phase 3), so the dataset can be
  read by anything that reads the web. Pure: takes `Spaces.Public.facts/1`
  and the site's base URL, returns a map ready for `Jason`.

  Types follow the kind, and for a place its subkind (a restaurant is a
  `Restaurant`, a museum a `Museum`); what schema.org has no word for is a
  `Thing`. The poets' own words ride under the `tp:` prefix: who found it
  and what they wrote, never presented as fact about the world.
  """

  @context %{
    "@vocab" => "https://schema.org/",
    "tp" => "https://poet.travel/ns#"
  }

  @place_types %{
    "restaurant" => "Restaurant",
    "cafe" => "CafeOrCoffeeShop",
    "bar_or_brewery" => "BarOrPub",
    "shop" => "Store",
    "market" => "Store",
    "museum" => "Museum",
    "gallery" => "ArtGallery",
    "exhibition" => "ExhibitionEvent",
    "park_or_garden" => "Park",
    "place_of_worship" => "PlaceOfWorship",
    "historic_site" => "LandmarksOrHistoricalBuildings",
    "building_or_monument" => "LandmarksOrHistoricalBuildings",
    "performance_venue" => "PerformingArtsTheater",
    "trail_or_viewpoint" => "TouristAttraction",
    "natural_site" => "TouristAttraction",
    "neighbourhood" => "Place",
    "city" => "City",
    "region" => "AdministrativeArea",
    "country" => "Country"
  }

  @kind_types %{
    "event" => "Event",
    "artwork" => "VisualArtwork",
    "dish" => "MenuItem",
    "person" => "Person",
    "product" => "Product",
    "work" => "CreativeWork",
    "idea" => "CreativeWork",
    "other" => "Thing"
  }

  @doc "The schema.org type for an item."
  def type(%{kind: "place", subkind: subkind}), do: Map.get(@place_types, subkind, "Place")
  def type(%{kind: kind}), do: Map.get(@kind_types, kind, "Thing")

  @doc "The JSON-LD document for `facts` (see `Spaces.Public.facts/1`)."
  def build(%{item: item} = facts, base_url) do
    url = item_url(base_url, item.slug)

    %{
      "@context" => @context,
      "@type" => type(item),
      "@id" => url,
      "url" => url,
      "name" => item.name,
      "sameAs" => item.source_url,
      "description" => first_note(facts.notes),
      "keywords" => keywords(facts.topics),
      "temporalCoverage" => item.era,
      "startDate" => iso(item.time_start),
      "endDate" => iso(item.time_end),
      "geo" => geo(item),
      "address" => address(item),
      "containedInPlace" => parent(facts.parent, base_url),
      "tp:foundBy" =>
        Enum.map(facts.poets, fn p ->
          %{"@type" => "Person", "name" => p.name, "url" => base_url <> "/p/" <> p.slug}
        end),
      "tp:notes" =>
        Enum.map(facts.notes, fn n ->
          %{
            "author" => n.poet.name,
            "dateCreated" => iso(n.date),
            "text" => n.blurb,
            "tp:rating" => n.rating,
            "url" => base_url <> "/p/" <> n.poet.slug <> "/" <> iso(n.date)
          }
          |> compact()
        end),
      "tp:earlierEditions" => Enum.map(facts.editions, &ref(&1, base_url))
    }
    |> Map.merge(links(facts.related, base_url))
    |> compact()
  end

  defp item_url(base_url, slug), do: base_url <> "/items/" <> slug

  defp ref(item, base_url),
    do: %{"@type" => type(item), "@id" => item_url(base_url, item.slug), "name" => item.name}

  defp first_note([%{blurb: blurb} | _]) when is_binary(blurb), do: blurb
  defp first_note(_), do: nil

  defp keywords([]), do: nil
  defp keywords(topics), do: Enum.map(topics, fn {_path, names} -> Enum.join(names, " > ") end)

  defp geo(%{lat: lat, lng: lng}) when is_number(lat) and is_number(lng),
    do: %{"@type" => "GeoCoordinates", "latitude" => lat, "longitude" => lng}

  defp geo(_), do: nil

  defp address(%{city: city, country_code: code}) when is_binary(city) or is_binary(code) do
    %{"@type" => "PostalAddress", "addressLocality" => city, "addressCountry" => code}
    |> compact()
  end

  defp address(_), do: nil

  defp parent(nil, _base_url), do: nil
  defp parent(parent, base_url), do: ref(parent, base_url)

  # The poet's links as schema.org properties, outgoing only: what this
  # item is at, part of, made by, commemorates, about. The other direction
  # is on the other item's document.
  @properties %{
    "at" => "location",
    "part_of" => "isPartOf",
    "made_by" => "creator",
    "commemorates" => "about",
    "about" => "about"
  }

  defp links(related, base_url) do
    related
    |> Enum.filter(&(&1.direction == :out and Map.has_key?(@properties, &1.relation)))
    |> Enum.group_by(&Map.fetch!(@properties, &1.relation), &ref(&1.item, base_url))
    |> Map.new(fn
      {prop, [one]} -> {prop, one}
      {prop, many} -> {prop, many}
    end)
  end

  defp iso(nil), do: nil
  defp iso(%Date{} = d), do: Date.to_iso8601(d)

  defp compact(map) do
    map
    |> Enum.reject(fn {_k, v} -> v in [nil, [], %{}] end)
    |> Map.new()
  end
end
