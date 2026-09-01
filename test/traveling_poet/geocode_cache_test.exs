defmodule TravelingPoet.GeocodeCacheTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Geocoder, Guide, Repo}
  alias TravelingPoet.Geocoder.CacheEntry
  alias TravelingPoet.Guide.Geocoding

  defp cache(query, attrs) do
    {:ok, entry} =
      %CacheEntry{}
      |> CacheEntry.changeset(
        Map.merge(
          %{
            query_hash: CacheEntry.hash(query),
            query: query,
            found: true,
            looked_up_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          attrs
        )
      )
      |> Repo.insert()

    entry
  end

  # Geocoding is switched off in :test. Nominatim needs no API key, so unlike
  # every other outbound service there is no credential to nil out -- this
  # switch is the only thing between the suite and live OSM traffic.
  test "geocoding is disabled in the test environment" do
    refute Geocoder.enabled?()
    assert Geocoder.locate("Tasca do Chico, Lisbon") == :not_found
  end

  test "a cached hit answers without touching the network" do
    cache("Tasca do Chico, Lisbon", %{lat: 38.71, lng: -9.14, country_code: "PT"})

    assert {:ok, %{lat: 38.71, lng: -9.14, country_code: "PT"}} =
             Geocoder.locate("Tasca do Chico, Lisbon")
  end

  test "the cache key ignores case and extra whitespace" do
    cache("Tasca do Chico, Lisbon", %{lat: 38.71, lng: -9.14})

    assert {:ok, %{lat: 38.71}} = Geocoder.locate("  TASCA   do Chico,  Lisbon ")
  end

  # OSM allows the whole app one request a second. Without a negative cache, a
  # single unfindable address costs a request on every re-put, forever.
  test "a remembered miss stays a miss, and does not re-ask" do
    query = "Nowhere at all"
    cache(query, %{found: false})

    assert Geocoder.locate(query) == :not_found
    assert Repo.get_by(CacheEntry, query_hash: CacheEntry.hash(query)).found == false
  end

  test "a stale miss expires so the place gets another chance" do
    query = "Newly opened bar"

    stale =
      DateTime.utc_now() |> DateTime.add(-60, :day) |> DateTime.truncate(:second)

    cache(query, %{found: false, looked_up_at: stale})

    # Still :not_found here only because geocoding is off in test; the point is
    # that the expired row is no longer treated as an authoritative answer.
    assert Geocoder.locate(query) == :not_found
  end

  describe "resolving places" do
    test "a place that cannot be located is marked failed and still lists" do
      user = user_fixture()
      poet = poet_fixture(user)
      entry = published_entry_fixture(poet)

      {:ok, _} =
        Guide.replace_places(entry, [%{"name" => "Nameless", "category" => "viewpoint"}])

      [place] = Guide.list_places_for_entry(entry.id)
      resolved = Geocoding.resolve(place, "Lisbon, Portugal")

      assert resolved.geocode_status == "failed"
      assert length(Guide.list_places(poet.id)) == 1
      assert Guide.map_payload(Guide.list_places(poet.id), poet.name) == []
    end

    test "an already-geocoded place is never looked up again" do
      user = user_fixture()
      poet = poet_fixture(user)
      entry = published_entry_fixture(poet)
      {:ok, _} = Guide.replace_places(entry, [%{"name" => "Ramiro", "category" => "restaurant"}])

      [place] = Guide.list_places_for_entry(entry.id)
      {:ok, geocoded} = Guide.update_geocode(place, %{lat: 38.72, lng: -9.13})

      assert Geocoding.resolve(geocoded, "Lisbon, Portugal") == geocoded
    end

    test "the budget pass reports which places got no pin" do
      user = user_fixture()
      poet = poet_fixture(user)
      entry = published_entry_fixture(poet)

      {:ok, _} =
        Guide.replace_places(entry, [
          %{"name" => "Found", "category" => "restaurant"},
          %{"name" => "Lost", "category" => "viewpoint"}
        ])

      places = Guide.list_places_for_entry(entry.id)
      {_resolved, not_located} = Geocoding.resolve_within_budget(places, "Lisbon, Portugal")

      assert Enum.sort(not_located) == ["Found", "Lost"]
    end
  end
end
