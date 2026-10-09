defmodule TravelingPoet.Spaces.Hierarchy do
  @moduledoc """
  The admin reference system (kb-002 phase 1): country > region > city, as
  items with a parent. A stay's place name as the geocoder wrote it
  ("Seattle, King County, Washington, United States") and its ISO country
  code are all the app knows, so the hierarchy is derived from those: the
  country by code (name from the last part of the place name), the region
  from the part before the country, the city from the stay itself.

  Every item under a city carries the city's `country_code`, so "the
  world's textile places, by country" is one query. Nothing here calls a
  geocoder; a stay without a code and with a one-word name ("Tainan") gets
  no country, and the backfill report says how many.
  """

  import Ecto.Query

  alias TravelingPoet.{Repo, Spaces}
  alias TravelingPoet.Poets.PathPoint
  alias TravelingPoet.Spaces.{Item, Resolver}

  @doc """
  The parts of a geocoder-style place name: `%{city, region, country}`.
  One part is a city; two are a city and its country; three or more put the
  country last and the region just before it, postcodes skipped.
  """
  def parse(nil), do: %{city: nil, region: nil, country: nil}

  def parse(name) when is_binary(name) do
    parts =
      name
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or Regex.match?(~r/^\d[\d\s-]*$/, &1)))

    case parts do
      [] -> %{city: nil, region: nil, country: nil}
      [city] -> %{city: city, region: nil, country: nil}
      [city, country] -> %{city: city, region: nil, country: country}
      [city | rest] -> %{city: city, region: Enum.at(rest, -2), country: List.last(rest)}
    end
  end

  @doc """
  Puts a city item under its region and country, creating those as needed
  from the stay's place name and country code, and stamps the country code.
  Fills only what the city lacks. Returns the city.
  """
  def attach(%Item{subkind: "city"} = city, place_name, country_code) do
    parsed = parse(place_name)
    country = ensure_country(normalize_code(country_code), parsed.country)
    region = if country, do: ensure_region(parsed.region, country)
    parent = region || country

    changes =
      [
        parent_id: if(is_nil(city.parent_id) and parent, do: parent.id),
        country_code: if(is_nil(city.country_code) and country, do: country.country_code)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    if changes == [],
      do: city,
      else: city |> Item.changeset(Map.new(changes)) |> Repo.update!()
  end

  def attach(item, _place_name, _country_code), do: item

  @doc "The country code an item inherits: its own, or the nearest ancestor's."
  def country_code_of(nil), do: nil
  def country_code_of(%Item{country_code: code}) when is_binary(code), do: code

  def country_code_of(%Item{parent_id: parent_id}) when is_integer(parent_id),
    do: country_code_of(Repo.get(Item, parent_id))

  def country_code_of(_), do: nil

  @doc """
  Places every city item that has no parent yet, from its newest stay, and
  carries country codes down to the items under the cities. Returns
  `%{cities_placed, countries, regions, coded}`.
  """
  def backfill do
    placed =
      Item
      |> where([i], i.subkind == "city" and i.status == "active" and is_nil(i.parent_id))
      |> Repo.all()
      |> Enum.count(fn city ->
        case newest_stay(city.id) do
          nil -> false
          stay -> not is_nil(attach(city, stay.place_name, stay.country_code).parent_id)
        end
      end)

    coded = propagate_codes()

    %{
      cities_placed: placed,
      countries: Repo.aggregate(from(i in Item, where: i.subkind == "country"), :count),
      regions: Repo.aggregate(from(i in Item, where: i.subkind == "region"), :count),
      coded: coded
    }
  end

  defp newest_stay(item_id) do
    PathPoint |> where(item_id: ^item_id) |> order_by(desc: :arrived_at) |> limit(1) |> Repo.one()
  end

  # Children take their parent's code; three passes cover country > region
  # > city > place.
  defp propagate_codes do
    Enum.reduce(1..3, 0, fn _, n ->
      n +
        (from(c in Item,
           join: p in Item,
           on: p.id == c.parent_id,
           where: is_nil(c.country_code) and not is_nil(p.country_code),
           select: {c.id, p.country_code}
         )
         |> Repo.all()
         |> Enum.map(fn {id, code} ->
           from(i in Item, where: i.id == ^id) |> Repo.update_all(set: [country_code: code])
           1
         end)
         |> Enum.sum())
    end)
  end

  defp normalize_code(code) when is_binary(code) do
    case code |> String.trim() |> String.upcase() do
      <<a, b>> when a in ?A..?Z and b in ?A..?Z -> <<a, b>>
      _ -> nil
    end
  end

  defp normalize_code(_), do: nil

  # By code when there is one (so "USA" and "United States" are one
  # country), else by name.
  defp ensure_country(nil, nil), do: nil

  defp ensure_country(code, name) do
    found =
      cond do
        code ->
          Item
          |> where([i], i.subkind == "country" and i.country_code == ^code)
          |> limit(1)
          |> Repo.one()

        true ->
          key = Resolver.name_key(name)

          Item
          |> where([i], i.subkind == "country" and i.norm_name == ^key)
          |> limit(1)
          |> Repo.one()
      end

    found ||
      create!(%{kind: "place", subkind: "country", name: name || code, country_code: code})
  end

  defp ensure_region(nil, _country), do: nil

  defp ensure_region(name, country) do
    key = Resolver.name_key(name)

    found =
      Item
      |> where([i], i.subkind == "region" and i.parent_id == ^country.id and i.norm_name == ^key)
      |> limit(1)
      |> Repo.one()

    found ||
      create!(%{
        kind: "place",
        subkind: "region",
        name: name,
        parent_id: country.id,
        country_code: country.country_code
      })
  end

  defp create!(attrs) do
    {:ok, item} = Spaces.create_item(attrs)
    item
  end
end
