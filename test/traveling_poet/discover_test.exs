defmodule TravelingPoet.DiscoverTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Discover, Journal}

  defp on_the_road(name, attrs \\ %{}) do
    poet_fixture(
      user_fixture(),
      Map.merge(%{name: name, is_public: true, status: "active"}, attrs)
    )
  end

  defp page(poet, date, attrs \\ %{}) do
    published_entry_fixture(
      poet,
      Map.merge(%{entry_date: date, title: "#{poet.name} #{date}", lat: 38.7, lng: -9.1}, attrs)
    )
  end

  describe "build/0" do
    test "public poets bring their pages and places; a private poet is only a blurred dot" do
      nam = on_the_road("Nam")
      lisbon = page(nam, ~D[2026-09-01], %{place_name: "Lisbon"})

      {:ok, _draft} =
        Journal.upsert_entry(nam.id, ~D[2026-09-02], %{title: "Draft", lat: 1.0, lng: 1.0})

      tasca = place_fixture(nam, lisbon, %{name: "Tasca", lat: 38.71, lng: -9.14})
      _unmapped = place_fixture(nam, lisbon, %{name: "Nowhere"})

      hilda =
        on_the_road("Hidden Hilda", %{
          is_public: false,
          current_lat: 13.7524938,
          current_lng: 100.4935089,
          current_place_name: "Bangkok, Thailand"
        })

      secret = page(hilda, ~D[2026-09-01], %{place_name: "Bangkok", title: "Secret page"})
      place_fixture(hilda, secret, %{name: "Secret noodle bar", lat: 13.75, lng: 100.49})

      d = Discover.build()

      assert [%{slug: slug, name: "Nam"}] = d.poets
      assert slug == nam.slug
      assert [%{id: id, poet: ^slug, place: "Lisbon", date: "2026-09-01"}] = d.entries
      assert id == lisbon.id
      assert [%{id: place_id, name: "Tasca", group: "food", poet: ^slug}] = d.places
      assert place_id == tasca.id
      assert d.rotation == [lisbon.id]
      assert d.anonymous == [%{lat: 13.8, lng: 100.5}]
      assert d.totals == %{poets: 2, entries: 1, places: 1}

      dump = inspect(d, limit: :infinity)
      refute dump =~ "Hilda"
      refute dump =~ "Bangkok"
      refute dump =~ "Secret"
      refute dump =~ "13.7524938"

      # It all goes to the hook as JSON.
      assert {:ok, _} = Jason.encode(d)
    end
  end

  describe "rotation/1" do
    test "newest first, one page per poet per round" do
      entries = [
        %{id: 1, poet: "a", date: "2026-09-01"},
        %{id: 2, poet: "a", date: "2026-09-02"},
        %{id: 3, poet: "a", date: "2026-09-03"},
        %{id: 4, poet: "b", date: "2026-08-20"},
        %{id: 5, poet: "c", date: "2026-09-02"},
        %{id: 6, poet: "c", date: "2026-08-01"}
      ]

      # Round one: a's newest (09-03), c's newest (09-02), b's only (08-20).
      # Round two: a's second (09-02), c's second (08-01). Round three: a's last.
      assert Discover.rotation(entries) == [3, 5, 4, 2, 6, 1]
    end

    test "is capped" do
      entries =
        for i <- 1..40,
            do: %{
              id: i,
              poet: "p#{rem(i, 4)}",
              date: Date.to_iso8601(Date.add(~D[2026-08-01], i))
            }

      assert length(Discover.rotation(entries)) == 30
    end
  end

  describe "the overviews" do
    test "load what is public and published, and nothing else" do
      nam = on_the_road("Nam")
      entry = page(nam, ~D[2026-09-01])
      drawing = media_fixture(nam, %{journal_entry_id: entry.id})
      place = place_fixture(nam, entry, %{lat: 38.7, lng: -9.1, media_id: drawing.id})
      {:ok, draft} = Journal.upsert_entry(nam.id, ~D[2026-09-05], %{title: "Draft"})
      draft_place = place_fixture(nam, draft, %{lat: 38.7, lng: -9.1})

      private = on_the_road("Hilda", %{is_public: false})
      private_entry = page(private, ~D[2026-09-01])
      private_place = place_fixture(private, private_entry, %{lat: 1.0, lng: 1.0})

      assert %{entry: %{id: id}, poet: %{name: "Nam"}, drawing: %{id: drawing_id}} =
               Discover.entry(to_string(entry.id))

      assert id == entry.id
      assert drawing_id == drawing.id
      assert %{place: %{id: pid}, drawing: %{id: ^drawing_id}} = Discover.place(place.id)
      assert pid == place.id
      assert %{poet: %{name: "Nam"}, stats: %{entries: 1, places: 1}} = Discover.poet(nam.slug)

      assert Discover.entry(draft.id) == nil
      assert Discover.place(draft_place.id) == nil
      assert Discover.entry(private_entry.id) == nil
      assert Discover.place(private_place.id) == nil
      assert Discover.poet(private.slug) == nil
      assert Discover.entry("1 OR 1=1") == nil
      assert Discover.entry(%{}) == nil
    end
  end
end
