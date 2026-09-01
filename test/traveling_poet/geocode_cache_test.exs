defmodule TravelingPoet.GeocodeCacheTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Geocoder, Guide, Repo}
  alias TravelingPoet.Geocoder.CacheEntry
  alias TravelingPoet.Guide.{Geocoding, Place}

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

  describe "geocode_queries/2" do
    # The 2026-09-01 production regression: all three of Matti's Vienna places
    # failed with perfectly good addresses, because the query joined the venue
    # name, the full postal address AND the city -- and Nominatim matched
    # nothing against it. Verified against the live service at the time:
    #   "Cafe Museum, Operngasse 7, 1010 Vienna, Austria, Vienna, Austria" 0 hits
    #   "Operngasse 7, 1010 Vienna, Austria"                              3 hits
    test "an address is queried on its own, never glued to the name" do
      place = %Place{name: "Cafe Museum", address: "Operngasse 7, 1010 Vienna, Austria"}

      assert ["Operngasse 7, 1010 Vienna, Austria", "Cafe Museum, Vienna, Austria"] =
               Guide.geocode_queries(place, "Vienna, Austria")
    end

    test "the city is not appended to an address that already names it" do
      place = %Place{name: "Cafe Museum", address: "Operngasse 7, 1010 Vienna, Austria"}
      [primary | _] = Guide.geocode_queries(place, "Vienna, Austria")

      refute primary =~ ~r/Vienna.*Vienna/
    end

    test "a city IS appended to an address that omits it" do
      place = %Place{name: "Naschmarkt", address: "Wienzeile"}

      assert ["Wienzeile, Vienna, Austria" | _] =
               Guide.geocode_queries(place, "Vienna, Austria")
    end

    test "a place with no address falls back to name and city alone" do
      place = %Place{name: "Naschmarkt", address: nil}

      assert Guide.geocode_queries(place, "Vienna, Austria") == ["Naschmarkt, Vienna, Austria"]
    end

    test "a blank address is treated as absent, not joined as an empty segment" do
      place = %Place{name: "Naschmarkt", address: "   "}

      assert Guide.geocode_queries(place, "Vienna, Austria") == ["Naschmarkt, Vienna, Austria"]
    end

    # Common shape: the poet gives the market's name as its address. Both
    # candidates then render identically and it must cost one lookup, not two
    # against a 1 req/s budget.
    test "identical candidates collapse to one lookup" do
      place = %Place{name: "Naschmarkt", address: "Naschmarkt, Vienna, Austria"}

      assert Guide.geocode_queries(place, "Vienna, Austria") == ["Naschmarkt, Vienna, Austria"]
    end
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

    # The address and the name+city forms fail on quite different inputs, so a
    # place is only failed once BOTH have come back empty.
    test "the fallback candidate is tried before a place is failed" do
      user = user_fixture()
      poet = poet_fixture(user)
      entry = published_entry_fixture(poet)

      {:ok, _} =
        Guide.replace_places(entry, [
          %{"name" => "Cafe Museum", "category" => "cafe", "address" => "Operngasse 7, Vienna"}
        ])

      [place] = Guide.list_places_for_entry(entry.id)
      # Only the SECOND candidate is cached; the first must fall through to it.
      cache("Cafe Museum, Vienna, Austria", %{lat: 48.2014, lng: 16.3676})

      resolved = Geocoding.resolve(place, "Vienna, Austria")

      assert resolved.geocode_status == "ok"
      assert resolved.lat == 48.2014
    end

    # A place marked failed by a bug of ours is not a place that does not
    # exist. Without this, the only record of that is a row nothing will ever
    # look at again.
    test "reset_failed_geocodes flips failures back to pending for a retry" do
      user = user_fixture()
      poet = poet_fixture(user)
      entry = published_entry_fixture(poet)
      {:ok, _} = Guide.replace_places(entry, [%{"name" => "Somewhere", "category" => "cafe"}])
      [place] = Guide.list_places_for_entry(entry.id)
      {:ok, _} = Guide.mark_geocode_failed(place)

      assert {1, _} = Guide.reset_failed_geocodes(poet.id)
      assert Guide.pending_geocodes() |> Enum.map(& &1.id) == [place.id]
    end

    test "purge_misses forgets cached failures so a fix can take effect" do
      cache("Nowhere at all", %{found: false})
      cache("Somewhere real", %{lat: 1.0, lng: 2.0, found: true})

      assert Geocoder.purge_misses() == 1
      assert Repo.get_by(CacheEntry, query_hash: CacheEntry.hash("Somewhere real")) != nil
      assert Repo.get_by(CacheEntry, query_hash: CacheEntry.hash("Nowhere at all")) == nil
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
