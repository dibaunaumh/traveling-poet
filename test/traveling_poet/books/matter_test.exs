defmodule TravelingPoet.Books.MatterTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Books.{Manuscript, Matter, Quotes}
  alias TravelingPoet.Journal.EntryBundle

  @poet %{id: 1, name: "Wren", slug: "wren", is_public: true, currently_reading: nil}

  defp stay(id, position, place, arrived) do
    %{
      id: id,
      position: position,
      place_name: place,
      country_code: nil,
      arrived_at: DateTime.new!(arrived, ~T[08:00:00], "Etc/UTC"),
      departed_at: nil
    }
  end

  defp section(kind, body, title \\ nil),
    do: %{kind: kind, position: 0, title: title, body: body, media_id: nil, metadata: %{}}

  defp bundle(date, stay_id, sections) do
    %EntryBundle{
      entry: %{
        id: Date.to_gregorian_days(date),
        entry_date: date,
        place_name: "Lisbon, Portugal",
        title: "A day",
        teaser: nil,
        sources: %{},
        sections: sections,
        excursion: nil
      },
      stay_id: stay_id
    }
  end

  defp manuscript do
    stays = [
      stay(11, 0, "Lisbon, Portugal", ~D[2026-03-01]),
      stay(12, 1, "Porto, Portugal", ~D[2026-03-04])
    ]

    Manuscript.build(
      @poet,
      [
        bundle(~D[2026-03-01], 11, [
          section(
            "description",
            "Lisbon is built on hills and the trams take them *personally*. I rode the 28 with my forehead on the glass.\n\nSee [the schedule](https://carris.pt) before you go."
          ),
          section(
            "poem",
            "Yellow box, iron song,\nyou take the hill the way\na grandmother takes stairs",
            "Tram 28"
          )
        ]),
        bundle(~D[2026-03-04], 12, [
          section("description", "Porto is Lisbon turned up a notch and painted blue.")
        ])
      ],
      stays
    )
  end

  describe "Quotes.validate/2" do
    test "a line copied word for word is accepted, however the typography drifted" do
      m = manuscript()

      {accepted, dropped} =
        Quotes.validate(
          [
            %{"entry_date" => "2026-03-01", "text" => "you take the hill the way"},
            # markdown emphasis gone, curly apostrophe-free, case changed, full stop kept
            %{
              "entry_date" => "2026-03-01",
              "text" => "Lisbon is built on hills and the trams take them personally."
            },
            # the link's text is what a reader saw
            %{"entry_date" => "2026-03-01", "text" => "See the schedule before you go"},
            %{"entry_date" => "2026-03-04", "text" => "“Porto is Lisbon turned up a notch”"}
          ],
          m
        )

      assert dropped == []
      assert length(accepted) == 4

      assert hd(accepted) == %{
               "entry_date" => "2026-03-01",
               "text" => "you take the hill the way"
             }
    end

    test "a reworded, stitched or misdated line is dropped with a reason the poet can act on" do
      m = manuscript()

      {accepted, dropped} =
        Quotes.validate(
          [
            %{"entry_date" => "2026-03-01", "text" => "you climb the hill the way"},
            %{
              "entry_date" => "2026-03-01",
              "text" => "Yellow box, iron song, a grandmother takes stairs"
            },
            %{"entry_date" => "2026-03-04", "text" => "you take the hill the way"},
            %{"entry_date" => "2026-03-02", "text" => "you take the hill the way"},
            %{"entry_date" => "yesterday", "text" => "you take the hill the way"},
            %{"entry_date" => "2026-03-01", "text" => "hills"}
          ],
          m
        )

      assert accepted == []

      assert Enum.map(dropped, & &1["reason"]) == [
               "not found word for word in that day's entry: quote it exactly",
               "not found word for word in that day's entry: quote it exactly",
               "not found word for word in that day's entry: quote it exactly",
               "no published entry on that date",
               "entry_date must be a date like 2026-09-01",
               "too short to stand on a page"
             ]
    end

    test "duplicates are dropped and the book holds at most eight" do
      m = manuscript()
      line = %{"entry_date" => "2026-03-01", "text" => "you take the hill the way"}
      {accepted, dropped} = Quotes.validate([line, line], m)
      assert length(accepted) == 1
      assert [%{"reason" => "already chosen"}] = dropped

      words =
        ~w(Lisbon is built on hills and the trams take them personally I rode the 28 with my)

      many =
        for n <- 3..12 do
          %{"entry_date" => "2026-03-01", "text" => Enum.take(words, n) |> Enum.join(" ")}
        end

      {accepted, dropped} = Quotes.validate(many, m)
      assert length(accepted) == 8
      assert Enum.all?(dropped, &(&1["reason"] == "only 8 quotes fit the book"))
    end

    test "quotables hand the poet its poem lines and first sentences, markdown removed" do
      q = Quotes.quotables(manuscript())

      assert q[~D[2026-03-01]].poem_lines == [
               "Yellow box, iron song,",
               "you take the hill the way",
               "a grandmother takes stairs"
             ]

      assert "Lisbon is built on hills and the trams take them personally." in q[~D[2026-03-01]].sentences
      assert "See the schedule before you go." in q[~D[2026-03-01]].sentences
    end
  end

  describe "Matter.merge/3" do
    test "writes what was sent, merges openers by chapter, and reports what is missing" do
      m = manuscript()

      {matter, report} =
        Matter.merge(
          %{},
          %{
            "dedication" => "  For Udi, who stayed home  ",
            "chapter_openers" => %{"11" => "Lisbon first.", "99" => "Nowhere."},
            "pull_quotes" => [
              %{"entry_date" => "2026-03-01", "text" => "you take the hill the way"},
              %{"entry_date" => "2026-03-01", "text" => "you climb the hill"}
            ]
          },
          m
        )

      assert matter["dedication"] == "For Udi, who stayed home"
      assert matter["chapter_openers"] == %{"11" => "Lisbon first."}

      assert matter["pull_quotes"] == [
               %{"entry_date" => "2026-03-01", "text" => "you take the hill the way"}
             ]

      assert report.written == ["dedication", "chapter_openers", "pull_quotes"]
      assert report.unknown_chapters == ["99"]
      assert report.missing_openers == ["12"]
      assert [%{"text" => "you climb the hill"}] = report.dropped_quotes
      assert Matter.landed?(matter)

      {matter, report} =
        Matter.merge(
          matter,
          %{"chapter_openers" => [%{"chapter" => 12, "text" => "Then Porto."}]},
          m
        )

      assert matter["chapter_openers"] == %{"11" => "Lisbon first.", "12" => "Then Porto."}
      assert report.missing_openers == []
      # untouched fields survive a partial put
      assert matter["dedication"] == "For Udi, who stayed home"
      assert length(matter["pull_quotes"]) == 1
    end

    test "a field over its limit is rejected on its own; the rest of the put lands" do
      {matter, report} =
        Matter.merge(
          %{"foreword" => "old"},
          %{"foreword" => String.duplicate("a", 2501), "epilogue" => "Home again."},
          manuscript()
        )

      assert matter["foreword"] == "old"
      assert matter["epilogue"] == "Home again."
      assert report.rejected == %{"foreword" => "longer than 2500 characters"}
    end

    test "nothing but openers and quotes is not a composed edition" do
      refute Matter.landed?(%{"chapter_openers" => %{"11" => "x"}, "epilogue" => "y"})
      refute Matter.landed?(%{"dedication" => "   "})
      assert Matter.landed?(%{"foreword" => "Before the road."})
    end

    test "for_render re-checks quotes against today's pages and groups them by day" do
      m = manuscript()

      render =
        Matter.for_render(
          %{
            "dedication" => "For Udi",
            "foreword" => "",
            "chapter_openers" => %{"11" => "Lisbon first.", "12" => " "},
            "pull_quotes" => [
              %{"entry_date" => "2026-03-01", "text" => "you take the hill the way"},
              # the entry was revised since: this line is gone from the page
              %{"entry_date" => "2026-03-01", "text" => "a line the poet later cut"}
            ]
          },
          m
        )

      assert render.dedication == "For Udi"
      assert render.foreword == nil
      assert render.openers == %{"11" => "Lisbon first."}
      assert render.quotes_by_date == %{~D[2026-03-01] => ["you take the hill the way"]}
    end
  end
end
