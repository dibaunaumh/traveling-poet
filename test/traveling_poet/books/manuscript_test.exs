defmodule TravelingPoet.Books.ManuscriptTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Books.{Index, Manuscript, Sources, Urls}
  alias TravelingPoet.Journal.EntryBundle

  @poet %{
    id: 1,
    name: "Wren",
    slug: "wren",
    is_public: true,
    currently_reading: %{"items" => [%{"title" => "Pessoa", "author" => "R. Zenith"}]}
  }

  defp stay(id, position, place, arrived, departed \\ nil) do
    %{
      id: id,
      position: position,
      place_name: place,
      country_code: nil,
      arrived_at: DateTime.new!(arrived, ~T[00:32:00], "Etc/UTC"),
      departed_at: departed && DateTime.new!(departed, ~T[00:32:00], "Etc/UTC")
    }
  end

  defp section(kind, body, extra \\ %{}),
    do:
      Map.merge(
        %{kind: kind, position: 0, title: nil, body: body, media_id: nil, metadata: %{}},
        extra
      )

  defp bundle(date, place, opts \\ []) do
    sections = Keyword.get(opts, :sections, [section("description", "Words about #{place}.")])

    entry = %{
      id: Date.to_gregorian_days(date),
      entry_date: date,
      place_name: place,
      title: "Day in #{place}",
      teaser: nil,
      sources: Keyword.get(opts, :entry_sources, %{}),
      sections: sections,
      excursion: Keyword.get(opts, :excursion)
    }

    %EntryBundle{
      entry: entry,
      media: Keyword.get(opts, :media, %{}),
      extra_media: Keyword.get(opts, :extra_media, []),
      spot_media: Keyword.get(opts, :spot_media, %{}),
      places: Keyword.get(opts, :places, []),
      finds: Keyword.get(opts, :finds, []),
      stay_id: Keyword.get(opts, :stay_id)
    }
  end

  defp place(name, opts \\ []),
    do: %{name: name, source_url: Keyword.get(opts, :url), media_id: nil, poet_rating: nil}

  describe "chapters" do
    test "follow the path in order, one per stay that has days, numbered without gaps" do
      stays = [
        stay(10, 0, "Fez, Morocco", ~D[2026-03-01], ~D[2026-03-01]),
        stay(11, 1, "Lisbon, Portugal", ~D[2026-03-01], ~D[2026-03-10]),
        stay(12, 2, "Porto, Portugal", ~D[2026-03-10])
      ]

      bundles = [
        bundle(~D[2026-03-01], "Lisbon, Portugal", stay_id: 11),
        bundle(~D[2026-03-02], "Lisbon, Portugal", stay_id: 11),
        bundle(~D[2026-03-11], "Porto, Portugal", stay_id: 12)
      ]

      m = Manuscript.build(@poet, bundles, stays, now: ~U[2026-09-15 12:00:00Z])

      assert Enum.map(m.chapters, &{&1.number, &1.title}) ==
               [{1, "Lisbon, Portugal"}, {2, "Porto, Portugal"}]

      [lisbon, porto] = m.chapters
      assert Enum.map(lisbon.days, & &1.number) == [1, 2]
      assert lisbon.from == ~D[2026-03-01] and lisbon.to == ~D[2026-03-02]
      assert porto.days |> hd() |> Map.get(:number) == 11
      assert m.entry_count == 3 and m.from == ~D[2026-03-01] and m.to == ~D[2026-03-11]
      assert m.colophon.chapter_count == 2 and m.colophon.generated_at == ~U[2026-09-15 12:00:00Z]
      assert m.title == "Wren"
      assert m.subtitle == "March 2026"

      assert Manuscript.build(
               @poet,
               [bundle(~D[2026-08-25], "Lisbon"), bundle(~D[2026-09-16], "Seville")],
               []
             ).subtitle ==
               "August to September 2026"
    end

    test "a day with no stay of its own is filed by the guide's rule, not dropped" do
      stays = [
        stay(10, 0, "Fez, Morocco", ~D[2026-03-01], ~D[2026-03-01]),
        stay(11, 1, "Louisville, USA", ~D[2026-03-01])
      ]

      # travel day: both stays cover the date; the entry is about the place moved TO
      [chapter] =
        Manuscript.build(@poet, [bundle(~D[2026-03-01], "Louisville, USA")], stays).chapters

      assert chapter.stay.id == 11
    end

    test "a poet with no path gets one chapter named after where it first wrote from" do
      m =
        Manuscript.build(
          @poet,
          [bundle(~D[2026-03-01], "Reno, USA"), bundle(~D[2026-03-02], "Reno, USA")],
          []
        )

      assert [%{number: 1, title: "Reno, USA", stay: %{id: nil}, days: [_, _]}] = m.chapters
    end

    test "an excursion day stays in the chapter of the stay it happened in" do
      stays = [stay(11, 0, "Lisbon, Portugal", ~D[2026-03-01])]
      excursion = %{topic: %{label: "Fado"}}

      m =
        Manuscript.build(
          @poet,
          [
            bundle(~D[2026-03-01], "Lisbon, Portugal", stay_id: 11),
            bundle(~D[2026-03-02], nil,
              stay_id: 11,
              excursion: excursion,
              finds: [%{name: "A talk", url: "https://x.org/t", media_id: nil}]
            )
          ],
          stays
        )

      assert [%{days: [_, excursion_day], finds: [%{name: "A talk"}]}] = m.chapters
      assert excursion_day.sources == [%{label: "A talk", url: "https://x.org/t", kind: "find"}]

      assert m.index.topics == [
               %{
                 term: "Fado",
                 refs: [%{chapter: 1, anchor: "day-2026-03-02", date: ~D[2026-03-02]}]
               }
             ]
    end

    test "chapter places are the days' places, once each" do
      stays = [stay(11, 0, "Lisbon, Portugal", ~D[2026-03-01])]

      m =
        Manuscript.build(
          @poet,
          [
            bundle(~D[2026-03-01], "Lisbon, Portugal",
              stay_id: 11,
              places: [place("Tasca do Chico"), place("Cafe A Brasileira")]
            ),
            bundle(~D[2026-03-02], "Lisbon, Portugal",
              stay_id: 11,
              places: [place("tasca do chico ")]
            )
          ],
          stays
        )

      assert [%{places: places}] = m.chapters
      assert Enum.map(places, & &1.name) == ["Tasca do Chico", "Cafe A Brasileira"]
    end

    test "an empty journal is an empty book, not a crash" do
      m = Manuscript.build(@poet, [], [])
      assert m.chapters == [] and m.entry_count == 0 and m.from == nil

      assert m.index == %{
               places: [],
               poems: [],
               books: [%{term: "Pessoa", author: "R. Zenith"}],
               topics: []
             }
    end
  end

  describe "cover_drawing" do
    test "is the journey's first real illustration, never the avatar or a spot" do
      avatar = %{id: 1, kind: "poet_avatar"}
      spot = %{id: 2, kind: "spot"}
      first = %{id: 3, kind: "illustration"}
      later = %{id: 4, kind: "illustration"}

      bundles = [
        # day 1 taped in the avatar as its drawing (entry #0 does this)
        bundle(~D[2026-03-01], "Lisbon, Portugal",
          sections: [section("illustration", nil, %{media_id: 1})],
          media: %{1 => avatar},
          spot_media: %{2 => spot}
        ),
        # day 2's drawing was never claimed by a section
        bundle(~D[2026-03-02], "Lisbon, Portugal", extra_media: [first]),
        bundle(~D[2026-03-03], "Lisbon, Portugal",
          sections: [section("illustration", nil, %{media_id: 4})],
          media: %{4 => later}
        )
      ]

      # given out of order, still the earliest day wins
      assert Manuscript.build(@poet, Enum.reverse(bundles), []).cover_drawing == first
    end

    test "a journey without drawings has none" do
      assert Manuscript.build(@poet, [bundle(~D[2026-03-01], "Reno, USA")], []).cover_drawing ==
               nil

      assert Manuscript.build(@poet, [], []).cover_drawing == nil
    end
  end

  describe "days" do
    # The base comes from `:phoenix_url` (runtime.exs sets it in every env,
    # including test). Read it rather than set it: this file is async and the
    # app env is shared with every other running test.
    test "carry the entry's own absolute page, public or private" do
      base = Application.fetch_env!(:traveling_poet, :phoenix_url)
      assert base =~ "http"

      [%{days: [day]}] =
        Manuscript.build(@poet, [bundle(~D[2026-03-01], "Lisbon, Portugal")], []).chapters

      assert day.url == "#{base}/p/wren/2026-03-01"
      assert day.anchor == "day-2026-03-01"

      assert Urls.entry_url(%{@poet | is_public: false}, day.entry) ==
               "#{base}/journal/2026-03-01"

      assert Urls.journal_url(@poet) == "#{base}/p/wren"
      assert Urls.guide_url(%{@poet | is_public: false}) == "#{base}/guide"
    end
  end

  describe "Sources.for_bundle/1" do
    test "gathers every cited link once, in reading order, dropping anything that is not http" do
      drawing = %{
        id: 7,
        sources: %{"items" => [%{"url" => "https://commons.org/a.jpg", "label" => "the square"}]}
      }

      spot = %{
        id: 8,
        sources: %{"items" => [%{"url" => "https://commons.org/b.jpg", "label" => nil}]}
      }

      stray = %{
        id: 9,
        sources: %{"items" => [%{"url" => "https://commons.org/a.jpg", "label" => "again"}]}
      }

      b =
        bundle(~D[2026-03-01], "Lisbon, Portugal",
          entry_sources: %{
            "items" => [
              %{"url" => "https://city.pt/today", "label" => "What's on"},
              %{"url" => "ftp://nope"}
            ]
          },
          sections: [
            section("illustration", nil, %{media_id: 7}),
            section("art_culture", "Fado tonight", %{
              title: "Fado",
              metadata: %{"source_url" => "https://fado.pt"}
            }),
            section("description", "x")
          ],
          media: %{7 => drawing},
          extra_media: [stray],
          spot_media: %{8 => spot},
          places: [place("Tasca do Chico", url: "https://tasca.pt"), place("No link")]
        )

      assert Sources.for_bundle(b) == [
               %{label: "What's on", url: "https://city.pt/today", kind: "entry"},
               %{label: "Fado", url: "https://fado.pt", kind: "section"},
               %{label: "the square", url: "https://commons.org/a.jpg", kind: "drawing"},
               %{
                 label: "https://commons.org/b.jpg",
                 url: "https://commons.org/b.jpg",
                 kind: "drawing"
               },
               %{label: "Tasca do Chico", url: "https://tasca.pt", kind: "place"}
             ]
    end

    test "an entry with nothing cited has no sources" do
      assert Sources.for_bundle(bundle(~D[2026-03-01], "Lisbon, Portugal")) == []
      assert Sources.for_bundle(%EntryBundle{}) == []
    end
  end

  describe "Index.build/2" do
    test "places and poems point at their days; terms sort case-folded; a poem is named by title or first line" do
      stays = [stay(11, 0, "Lisbon, Portugal", ~D[2026-03-01])]

      bundles = [
        bundle(~D[2026-03-01], "Lisbon, Portugal",
          stay_id: 11,
          places: [place("Tasca do Chico")],
          sections: [section("poem", "## Tram 28\n\nyellow clatter", %{title: nil})]
        ),
        bundle(~D[2026-03-02], "Lisbon, Portugal",
          stay_id: 11,
          places: [place("alfama steps"), place("Tasca do Chico")],
          sections: [section("poem", "body", %{title: "Ode to a sardine"})]
        )
      ]

      index = Manuscript.build(@poet, bundles, stays).index

      assert Enum.map(index.places, &{&1.term, Enum.map(&1.refs, fn r -> r.anchor end)}) == [
               {"alfama steps", ["day-2026-03-02"]},
               {"Tasca do Chico", ["day-2026-03-01", "day-2026-03-02"]}
             ]

      assert Enum.map(index.poems, & &1.term) == ["Ode to a sardine", "Tram 28"]
      assert index.books == [%{term: "Pessoa", author: "R. Zenith"}]
    end

    test "a long first line is cut on a word" do
      long = String.duplicate("lantern ", 12)

      [%{term: term}] =
        Index.build(
          [
            %{
              number: 1,
              days: [
                %{
                  anchor: "a",
                  date: ~D[2026-03-01],
                  entry: %{sections: [section("poem", long)]},
                  bundle: %EntryBundle{}
                }
              ]
            }
          ],
          @poet
        ).poems

      assert String.ends_with?(term, "...")
      assert byte_size(term) <= 64
      refute term =~ "lantern l..."
    end
  end
end
