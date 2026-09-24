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

  describe "the village" do
    @weaving "crafts-and-design/textiles/weaving-and-silk"
    @jazz "music-and-performance/music/jazz"

    defp tag(place, topic, second \\ nil) do
      place
      |> TravelingPoet.Guide.Place.topics_changeset(%{
        topic: topic,
        second_topic: second,
        place_type: "museum",
        topics_classified_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> TravelingPoet.Repo.update!()
    end

    test "public places by subject, merged by name and city, mapped or not" do
      nam = on_the_road("Nam")
      wren = on_the_road("Wren")
      kyoto1 = page(nam, ~D[2026-09-01], %{place_name: "Kyoto"})
      kyoto2 = page(wren, ~D[2026-09-05], %{place_name: "Kyoto"})

      # the same textile centre, logged by two poets; one row has no coordinates
      a = place_fixture(nam, kyoto1, %{name: "Nishijin Textile Center"}) |> tag(@weaving)
      b = place_fixture(wren, kyoto2, %{name: " nishijin textile center"}) |> tag(@weaving, @jazz)
      _untagged = place_fixture(nam, kyoto1, %{name: "Kyoto"})

      hidden = on_the_road("Hilda", %{is_public: false})
      secret = page(hidden, ~D[2026-09-01], %{place_name: "Kyoto"})

      place_fixture(hidden, secret, %{name: "Secret weaving shed", lat: 1.0, lng: 1.0})
      |> tag(@weaving)

      %{village: village} = Discover.build()

      assert length(village.tree) == 12
      assert [merged] = village.places
      # the newest row stands for the place; both poets and both topics are kept
      assert merged.id == b.id
      refute merged.id == a.id
      assert merged.city == "Kyoto"
      assert merged.date == "2026-09-05"
      assert Enum.sort(merged.poets) == Enum.sort([nam.slug, wren.slug])
      assert Enum.sort(merged.topics) == Enum.sort([@weaving, @jazz])
      refute inspect(village) =~ "Secret"
    end

    test "a place's overview names the other poets and borrows the page's drawing" do
      nam = on_the_road("Nam")
      wren = on_the_road("Wren")
      e1 = page(nam, ~D[2026-09-01], %{place_name: "Kyoto"})
      e2 = page(wren, ~D[2026-09-05], %{place_name: "Kyoto"})
      drawing = media_fixture(wren, %{journal_entry_id: e2.id})
      place_fixture(nam, e1, %{name: "Nishijin Textile Center"})
      mine = place_fixture(wren, e2, %{name: "Nishijin Textile Center"})

      overview = Discover.place(mine.id)
      assert [%{name: "Nam"}] = overview.also
      assert overview.drawing.id == drawing.id
      assert overview.drawing_from == :entry
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
