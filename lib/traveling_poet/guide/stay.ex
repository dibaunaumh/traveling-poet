defmodule TravelingPoet.Guide.Stay do
  @moduledoc """
  Where to stay (card-90). On the first day at each Trip Scout stop the poet
  weighs a few neighbourhoods against what the reader travels for and puts
  them as `StayArea`s; the app finds each on the map and counts the poet's
  places within a short walk of it, so the page can say "eleven places to
  eat, three shops" rather than take the poet's word for it.

  The judgement (what an area is like, who it suits, the one to pick) is the
  poet's. The counting is the app's, as everywhere else (CLAUDE.md, "the app
  counts, the poet never does").
  """
  import Ecto.Query

  alias TravelingPoet.{Geo, Geocoder, Repo}
  alias TravelingPoet.Guide.{Place, StayArea}
  alias TravelingPoet.Journal.Entry

  # About ten minutes on foot.
  @walk_km 0.8
  @max_areas 5
  # Places further than this from every area are another town's.
  @city_km 15
  @geocode_budget_ms 8_000

  def walk_km, do: @walk_km
  def max_areas, do: @max_areas

  @doc """
  Replaces an entry's areas with these (a re-put rewrites them, as places
  do), then finds them on the map within a short budget. `city` is where the
  poet is; it scopes the geocoding ("Kazimierz" alone is ambiguous).
  """
  def replace_areas(%Entry{} = entry, attrs_list, city) when is_list(attrs_list) do
    {:ok, areas} =
      Repo.transaction(fn ->
        Repo.delete_all(from(a in StayArea, where: a.journal_entry_id == ^entry.id))

        attrs_list
        |> Enum.take(@max_areas)
        |> Enum.with_index()
        |> Enum.flat_map(fn {attrs, i} ->
          attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

          %StayArea{}
          |> StayArea.changeset(%{
            poet_id: entry.poet_id,
            journal_entry_id: entry.id,
            city: city,
            name: attrs["name"],
            summary: attrs["summary"],
            best_for: attrs["best_for"],
            tradeoffs: attrs["tradeoffs"],
            recommended: attrs["recommended"] in [true, "true"],
            position: i
          })
          |> Repo.insert()
          |> case do
            {:ok, area} -> [area]
            {:error, _} -> []
          end
        end)
      end)

    {:ok, locate_within_budget(areas)}
  end

  defp locate_within_budget(areas) do
    deadline = System.monotonic_time(:millisecond) + @geocode_budget_ms

    Enum.map(areas, fn area ->
      if System.monotonic_time(:millisecond) < deadline, do: locate(area), else: area
    end)
  end

  defp locate(%StayArea{} = area) do
    case Geocoder.locate("#{area.name}, #{area.city}") do
      {:ok, %{lat: lat, lng: lng}} ->
        area |> StayArea.changeset(%{lat: lat, lng: lng, geocode_status: "ok"}) |> Repo.update!()

      :not_found ->
        area |> StayArea.changeset(%{geocode_status: "failed"}) |> Repo.update!()

      {:error, _} ->
        area
    end
  end

  @doc "Areas by entry id, in the poet's order."
  def list_for_entries([]), do: %{}

  def list_for_entries(entry_ids) do
    StayArea
    |> where([a], a.journal_entry_id in ^entry_ids)
    |> order_by(asc: :position)
    |> Repo.all()
    |> Enum.group_by(& &1.journal_entry_id)
  end

  @doc "Has this poet already weighed where to stay in this city?"
  def weighed?(poet_id, city) when is_binary(city) do
    city = String.downcase(String.trim(city))

    StayArea
    |> where([a], a.poet_id == ^poet_id and fragment("lower(trim(?))", a.city) == ^city)
    |> Repo.exists?()
  end

  def weighed?(_poet_id, _city), do: false

  @doc """
  The areas with what lies within a short walk of each, the recommended one
  first and then by how much is near. `places` is every mapped place of the
  poet's; those far from all areas are ignored.
  """
  def ranked(areas, places) do
    areas
    |> Enum.map(&%{area: &1, near: near(&1, places)})
    |> Enum.sort_by(fn %{area: a, near: n} -> {!a.recommended, -n.total, a.position} end)
  end

  @doc "Counts of places within a short walk of an area, by kind. Pure."
  def near(%StayArea{} = area, places) do
    if StayArea.mapped?(area) do
      close =
        Enum.filter(places, fn p ->
          Place.mapped?(p) and Geo.distance_km(area.lat, area.lng, p.lat, p.lng) <= @walk_km
        end)

      counts = Enum.frequencies_by(close, &kind/1)

      %{
        food: Map.get(counts, :food, 0),
        shops: Map.get(counts, :shops, 0),
        sights: Map.get(counts, :sights, 0),
        total: length(close)
      }
    else
      %{food: 0, shops: 0, sights: 0, total: 0}
    end
  end

  defp kind(%{category: "shop"}), do: :shops
  defp kind(%{category: c}) when c in ~w(restaurant cafe), do: :food
  defp kind(_), do: :sights

  @doc """
  The poet's mapped places around these areas: the pool `ranked/2` counts
  from, gathered from every day the poet spent nearby, not only this one.
  """
  def places_near(_poet_id, []), do: []

  def places_near(poet_id, areas) do
    centres = Enum.filter(areas, &StayArea.mapped?/1)

    if centres == [] do
      []
    else
      Place
      |> where([p], p.poet_id == ^poet_id and not is_nil(p.lat) and not is_nil(p.lng))
      |> Repo.all()
      |> Enum.filter(fn p ->
        Enum.any?(centres, &(Geo.distance_km(&1.lat, &1.lng, p.lat, p.lng) <= @city_km))
      end)
    end
  end
end
