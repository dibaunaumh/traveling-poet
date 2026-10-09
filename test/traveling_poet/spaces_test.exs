defmodule TravelingPoet.SpacesTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Discover, Guide, Poets, Repo, Spaces, Topics}
  alias TravelingPoet.Guide.Place
  alias TravelingPoet.Spaces.{Backfill, Ingest, Item, ItemReview, Resolver}
  alias TravelingPoet.Topics.Find

  defp on_the_road(name, attrs \\ %{}) do
    poet_fixture(
      user_fixture(),
      Map.merge(%{name: name, is_public: true, status: "active"}, attrs)
    )
  end

  defp page(poet, date, attrs) do
    published_entry_fixture(
      poet,
      Map.merge(%{entry_date: date, title: "#{poet.name} #{date}", lat: 35.0, lng: 135.7}, attrs)
    )
  end

  defp put_places(entry, places) do
    {:ok, places} = Guide.replace_places(entry, places)
    places
  end

  describe "the reference systems" do
    test "the travel deployment has geo, subject and time" do
      assert Enum.map(Spaces.list_reference_systems(), &{&1.key, &1.type}) == [
               {"geo", "metric"},
               {"subject", "tree"},
               {"time", "time"}
             ]
    end
  end

  describe "Resolver.decide/2" do
    defp item(attrs) do
      Map.merge(
        %{id: 1, norm_name: "", city: nil, lat: nil, lng: nil, source_url: nil, subkind: nil},
        attrs
      )
    end

    test "the same name in the same city is one item; in another city it is not" do
      kyoto = item(%{norm_name: "central market", city: "Kyoto"})
      probe = %{norm_name: "central market", city: "kyoto ", lat: nil, lng: nil}

      assert {:match, ^kyoto} = Resolver.decide(probe, [kyoto])
      assert {:new, []} = Resolver.decide(%{probe | city: "Lisbon"}, [kyoto])
    end

    test "a pin within 200 m and a near-identical name is one item; a different name is not" do
      centre = item(%{norm_name: "nishijin textile centre", lat: 35.03, lng: 135.75})
      probe = %{norm_name: "nishijin textile center", lat: 35.0305, lng: 135.7503}

      assert {:match, ^centre} = Resolver.decide(probe, [centre])

      assert {:new, []} =
               Resolver.decide(%{probe | norm_name: "museum of contemporary art"}, [centre])
    end

    test "a similar name in the same city is new, with the lookalike handed back for review" do
      mocak = item(%{norm_name: "mocak museum", city: "Krakow"})
      probe = %{norm_name: "mocak museum of art", city: "Krakow", lat: nil, lng: nil}

      assert {:new, [^mocak]} = Resolver.decide(probe, [mocak])
    end

    test "a city matches within 10 km, whatever it was called" do
      lisbon = item(%{norm_name: "lisbon portugal", subkind: "city", lat: 38.72, lng: -9.14})

      probe = %{norm_name: "lisboa", subkind: "city", lat: 38.75, lng: -9.15}
      assert {:match, ^lisbon} = Resolver.decide(probe, [lisbon])

      # Sintra is 25 km out: another stay
      probe = %{norm_name: "sintra", subkind: "city", lat: 38.80, lng: -9.39}
      assert {:new, []} = Resolver.decide(probe, [lisbon])
    end

    test "the same page is the same find, whatever it was called" do
      paper =
        item(%{
          norm_name: "attention is all you need",
          source_url: "https://arxiv.org/abs/1706.03762"
        })

      probe = %{
        kind: "idea",
        norm_name: "transformers paper",
        source_url: "http://www.arxiv.org/abs/1706.03762/"
      }

      assert {:match, ^paper} = Resolver.decide(probe, [paper])
    end

    test "two events citing one museum page stay two items; two finds citing one page are one" do
      museum =
        item(%{
          norm_name: "kyoto city kyocera museum of art",
          city: "Kyoto",
          source_url: "https://kyotocity-kyocera.museum/exhibition/1"
        })

      probe = %{
        kind: "event",
        norm_name: "zen and ghibli exhibition",
        city: "Kyoto",
        lat: nil,
        lng: nil,
        source_url: "https://kyotocity-kyocera.museum/exhibition/1"
      }

      assert {:new, []} = Resolver.decide(probe, [museum])

      assert {:match, ^museum} = Resolver.decide(%{probe | kind: "idea"}, [museum])
    end

    test "a place inside a neighbourhood is not a review candidate for it" do
      fremont = item(%{norm_name: "fremont", city: "Seattle", subkind: "neighbourhood"})

      probe = %{
        norm_name: "fremont troll",
        city: "Seattle",
        lat: nil,
        lng: nil,
        subkind: "attraction"
      }

      assert {:new, []} = Resolver.decide(probe, [fremont])
    end

    test "name_key keeps every script, drops accents, case and punctuation" do
      assert Resolver.name_key("京都市, 京都府, 日本") == "京都市 京都府 日本"
      assert Resolver.name_key("Dylan's Café!") == "dylans cafe"
      assert Resolver.name_key(nil) == ""
    end

    test "url_key strips what does not identify the page" do
      assert Resolver.url_key("HTTPS://www.Example.com/a/b/?utm=1#x") == "example.com/a/b"
      assert Resolver.url_key("") == nil
      assert Resolver.url_key(nil) == nil
    end
  end

  describe "places become visits of shared items" do
    @weaving "crafts-and-design/textiles/weaving-and-silk"

    test "two poets logging the same place in the same city share one item" do
      nam = on_the_road("Nam")
      wren = on_the_road("Wren")

      [a] =
        put_places(page(nam, ~D[2026-09-01], %{place_name: "Kyoto"}), [
          %{name: "Nishijin Textile Center", category: "attraction"}
        ])

      [b] =
        put_places(page(wren, ~D[2026-09-05], %{place_name: "Kyoto"}), [
          %{name: " nishijin textile center", category: "shop"}
        ])

      assert a.item_id == b.item_id
      item = Spaces.get_item(a.item_id)
      assert item.kind == "place"
      assert item.name == "Nishijin Textile Center"
      assert item.city == "Kyoto"
      assert item.slug == "nishijin-textile-center"
      assert item.first_poet_id == nam.id

      assert Enum.map(Spaces.found_by(item.id), & &1.id) |> Enum.sort() ==
               Enum.sort([nam.id, wren.id])
    end

    test "the same name in another city is another item, with a distinct slug" do
      nam = on_the_road("Nam")

      [a] =
        put_places(page(nam, ~D[2026-09-01], %{place_name: "Kyoto"}), [
          %{name: "Central Market", category: "shop"}
        ])

      [b] =
        put_places(page(nam, ~D[2026-09-03], %{place_name: "Lisbon"}), [
          %{name: "Central Market", category: "shop"}
        ])

      refute a.item_id == b.item_id
      assert Spaces.get_item(b.item_id).slug == "central-market-2"
    end

    test "a re-put keeps the item, and an event is an event with its dates" do
      nam = on_the_road("Nam")
      entry = page(nam, ~D[2026-09-01], %{place_name: "Kyoto"})

      [first] =
        put_places(entry, [
          %{
            name: "Gion Matsuri",
            category: "event",
            starts_on: ~D[2026-07-01],
            ends_on: ~D[2026-07-31]
          }
        ])

      [again] = put_places(entry, [%{name: "Gion Matsuri", category: "event"}])

      assert first.item_id == again.item_id
      item = Spaces.get_item(again.item_id)
      assert item.kind == "event"
      assert item.time_start == ~D[2026-07-01]
      assert item.time_end == ~D[2026-07-31]

      assert Repo.aggregate(Item, :count, :id) ==
               1 + Repo.aggregate(from(i in Item, where: i.subkind == "city"), :count, :id)
    end

    test "a pin from the geocoder and a subject from the classifier reach the item" do
      nam = on_the_road("Nam")

      [place] =
        put_places(page(nam, ~D[2026-09-01], %{place_name: "Kyoto"}), [
          %{name: "Kinkaku-ji", category: "landmark"}
        ])

      assert Spaces.get_item(place.item_id).lat == nil

      {:ok, place} = Guide.update_geocode(place, %{lat: 35.0394, lng: 135.7292})
      item = Spaces.get_item(place.item_id)
      assert item.lat == 35.0394
      assert item.geocode_status == "ok"

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      place
      |> Place.topics_changeset(%{topic: @weaving, topics_classified_at: now})
      |> Repo.update!()
      |> Ingest.topics_tagged()

      assert Spaces.get_item(place.item_id).topic == @weaving
    end

    test "a place with a pin merges across spellings of the city" do
      nam = on_the_road("Nam")
      wren = on_the_road("Wren")

      [a] =
        put_places(page(nam, ~D[2026-09-01], %{place_name: "Kyoto"}), [
          %{name: "Nishijin Textile Centre", category: "attraction"}
        ])

      {:ok, a} = Guide.update_geocode(a, %{lat: 35.03, lng: 135.75})

      [b] =
        put_places(page(wren, ~D[2026-09-05], %{place_name: "Kyoto, Japan"}), [
          %{
            name: "Nishijin Textile Center",
            category: "attraction",
            lat: 35.0302,
            lng: 135.7501,
            geocode_status: "ok"
          }
        ])

      assert a.item_id == b.item_id
    end

    test "a lookalike in the same city is a new item with a review row" do
      nam = on_the_road("Nam")
      entry = page(nam, ~D[2026-09-01], %{place_name: "Krakow"})

      [a, b] =
        put_places(entry, [
          %{name: "MOCAK Museum", category: "attraction"},
          %{name: "MOCAK Museum of Art", category: "attraction"}
        ])

      refute a.item_id == b.item_id
      assert [%ItemReview{item_id: item_id, candidate_id: candidate_id}] = Spaces.open_reviews()
      assert item_id == b.item_id
      assert candidate_id == a.item_id
    end

    test "a stay is a city item, and the places found during it hang off it" do
      nam = on_the_road("Nam")

      {:ok, nam} =
        Poets.move_to(nam, %{
          lat: 35.0116,
          lng: 135.7681,
          place_name: "Kyoto, Japan",
          country_code: "JP"
        })

      stay = Poets.current_path_point(nam.id)
      assert stay.item_id
      city = Spaces.get_item(stay.item_id)
      assert city.subkind == "city"
      assert city.lat == 35.0116

      [place] =
        put_places(page(nam, ~D[2026-09-01], %{place_name: "Kyoto, Japan"}), [
          %{name: "Kinkaku-ji", category: "landmark"}
        ])

      assert Spaces.get_item(place.item_id).parent_id == city.id

      # a second poet arriving nearby stays in the same city item
      wren = on_the_road("Wren")

      {:ok, wren} =
        Poets.move_to(wren, %{lat: 35.02, lng: 135.76, place_name: "Kyoto", country_code: "JP"})

      assert Poets.current_path_point(wren.id).item_id == city.id
      assert length(Spaces.stays_at(city.id)) == 2
    end
  end

  describe "finds become visits of shared items" do
    test "the same page or the same name is one item, keyed by kind" do
      nam = on_the_road("Nam")
      wren = on_the_road("Wren")
      e1 = page(nam, ~D[2026-09-01], %{place_name: nil})
      e2 = page(wren, ~D[2026-09-02], %{place_name: nil})

      {:ok, [a]} =
        Topics.replace_finds(e1, [
          %{
            name: "Attention Is All You Need",
            url: "https://arxiv.org/abs/1706.03762",
            kind: "paper"
          }
        ])

      {:ok, [b]} =
        Topics.replace_finds(e2, [
          %{
            name: "The transformer paper",
            url: "http://www.arxiv.org/abs/1706.03762/",
            kind: "paper"
          }
        ])

      {:ok, [c]} =
        Topics.replace_finds(page(nam, ~D[2026-09-03], %{place_name: nil}), [
          %{name: "Dune", url: "https://example.com/dune-book", kind: "book"}
        ])

      {:ok, [d]} =
        Topics.replace_finds(page(wren, ~D[2026-09-04], %{place_name: nil}), [
          %{name: "Dune", url: "https://example.com/dune-film", kind: "screen"}
        ])

      assert a.item_id == b.item_id
      assert Spaces.get_item(a.item_id).kind == "idea"
      assert Spaces.get_item(a.item_id).source_url == "https://arxiv.org/abs/1706.03762"
      # a book and a film called Dune are both works, same name, no pin: one item
      assert c.item_id == d.item_id
      assert Spaces.get_item(c.item_id).kind == "work"

      # one poet's find gets classified; the village tile then counts both
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      ai = "literature-and-ideas/fields-of-thought/ai-and-computing"

      a
      |> Find.topics_changeset(%{topic: ai, topics_classified_at: now})
      |> Repo.update!()
      |> Ingest.topics_tagged()

      assert [%{found_by: 2, topics: [^ai]}] = Discover.village().finds
    end
  end

  describe "the village reads through items" do
    @weaving "crafts-and-design/textiles/weaving-and-silk"

    test "one tile per item across poets and city spellings; a private poet's visits never surface" do
      nam = on_the_road("Nam")
      wren = on_the_road("Wren")

      [a] =
        put_places(page(nam, ~D[2026-09-01], %{place_name: "Kyoto"}), [
          %{name: "Nishijin Textile Centre", category: "attraction"}
        ])

      {:ok, a} = Guide.update_geocode(a, %{lat: 35.03, lng: 135.75})

      [b] =
        put_places(page(wren, ~D[2026-09-05], %{place_name: "Kyoto, Japan"}), [
          %{
            name: "Nishijin Textile Center",
            category: "attraction",
            lat: 35.0302,
            lng: 135.7501,
            geocode_status: "ok"
          }
        ])

      assert a.item_id == b.item_id

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      a
      |> Place.topics_changeset(%{topic: @weaving, topics_classified_at: now})
      |> Repo.update!()
      |> Ingest.topics_tagged()

      hidden = on_the_road("Hilda", %{is_public: false})

      [secret] =
        put_places(page(hidden, ~D[2026-09-02], %{place_name: "Kyoto"}), [
          %{name: "Nishijin Textile Centre", category: "attraction"}
        ])

      assert secret.item_id == a.item_id

      assert [tile] = Discover.village().places
      assert tile.item_id == a.item_id
      assert tile.found_by == 2
      assert Enum.sort(tile.ids) == Enum.sort([a.id, b.id])
      assert tile.topics == [@weaving]

      assert [%{name: "Nam"}] = Discover.place(b.id).also
      refute Enum.any?(Spaces.found_by(a.item_id), &(&1.id == hidden.id))
    end
  end

  describe "Backfill.run/1" do
    setup do
      nam = on_the_road("Nam")
      wren = on_the_road("Wren")
      {:ok, _} = Poets.move_to(nam, %{lat: 35.01, lng: 135.77, place_name: "Kyoto, Japan"})
      {:ok, _} = Poets.move_to(wren, %{lat: 35.02, lng: 135.76, place_name: "Kyoto"})
      e1 = page(nam, ~D[2026-09-01], %{place_name: "Kyoto"})
      e2 = page(wren, ~D[2026-09-05], %{place_name: "Kyoto"})
      # written before Spaces existed: no item on any of them
      a = place_fixture(nam, e1, %{name: "Nishijin Textile Center"})
      b = place_fixture(wren, e2, %{name: "nishijin textile center"})
      f = find_fixture(nam, e1, %{name: "A talk", kind: "talk"})
      Repo.update_all(from(p in TravelingPoet.Poets.PathPoint), set: [item_id: nil])
      Repo.delete_all(Item)
      %{a: a, b: b, f: f}
    end

    test "a dry run reports and writes nothing", %{a: a} do
      report = Backfill.run()

      refute report.committed
      assert report.linked.places == 2
      assert report.linked.finds == 1
      assert report.linked.stays == 2
      assert report.shared == 1
      assert [%{name: "Nishijin Textile Center", poets: 2}] = report.samples
      assert Repo.aggregate(Item, :count, :id) == 0
      assert Repo.get(Place, a.id).item_id == nil
    end

    test "a commit links every row, and a second run has nothing left", %{a: a, b: b, f: f} do
      report = Backfill.run(commit: true)
      assert report.committed
      assert Repo.get(Place, a.id).item_id == Repo.get(Place, b.id).item_id
      assert Repo.get(Find, f.id).item_id
      assert report.items_created == report.by_kind |> Map.values() |> Enum.sum()

      again = Backfill.run(commit: true)
      assert again.linked == %{stays: 0, places: 0, finds: 0, areas: 0}
      assert again.items_created == 0
    end
  end

  describe "links" do
    test "relate two items once, never an item to itself" do
      {:ok, dish} = Spaces.create_item(%{kind: "dish", name: "Yudofu"})
      {:ok, restaurant} = Spaces.create_item(%{kind: "place", name: "Okutan"})

      assert {:ok, _} = Spaces.link(dish.id, restaurant.id, "at", source: "poet")
      assert {:ok, _} = Spaces.link(dish.id, restaurant.id, "at", source: "poet")
      assert [%{relation: "at"}] = Spaces.links_from(dish.id)
      assert {:error, changeset} = Spaces.link(dish.id, dish.id, "same_as")
      assert "cannot link an item to itself" in errors_on(changeset).to_item_id
    end

    test "a merged item's slug resolves to the item that absorbed it" do
      {:ok, keep} = Spaces.create_item(%{kind: "place", name: "Kinkaku-ji"})
      {:ok, gone} = Spaces.create_item(%{kind: "place", name: "Golden Pavilion"})
      gone |> Item.changeset(%{status: "merged", merged_into_id: keep.id}) |> Repo.update!()

      assert Spaces.get_item_by_slug("golden-pavilion").id == keep.id
    end
  end
end
