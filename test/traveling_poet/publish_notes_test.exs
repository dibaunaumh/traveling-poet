defmodule TravelingPoet.PublishNotesTest do
  @moduledoc """
  The words that go out when an entry is published. Pure builders: the same
  sentence every morning is what taught readers to ignore the notes, so these
  pin that the day, the poet and the poet's own hook all make it in.
  """
  use ExUnit.Case, async: true

  alias TravelingPoet.Telegram.Notifier
  alias TravelingPoet.WebPush

  @poet %{name: "Nam", slug: "nam", is_public: true, current_place_name: "Lisbon"}
  @entry %{
    id: 7,
    entry_date: ~D[2026-09-11],
    title: "The rooftop nobody mentions",
    teaser: "I found a rooftop over the mosque where the swifts come in at dusk.",
    place_name: "Cordoba"
  }

  describe "Telegram" do
    test "leads with the day, the poet and the teaser, then the entry's own link" do
      link = Notifier.entry_link(@poet, @entry)
      assert String.ends_with?(link, "/p/nam/2026-09-11")

      text = Notifier.publish_text(@poet, @entry, 17, link)

      assert text ==
               "Day 17 · Nam: I found a rooftop over the mosque where the swifts come in at dusk.\n" <>
                 link
    end

    test "falls back to the title, then to the place, when the poet wrote no teaser" do
      assert Notifier.publish_text(@poet, %{@entry | teaser: "  "}, 3, "L") =~
               "Day 3 · Nam: The rooftop nobody mentions"

      assert Notifier.publish_text(@poet, %{@entry | teaser: nil, title: nil}, 3, "L") =~
               "Day 3 · Nam: a new entry from Cordoba"
    end

    test "an excursion entry with no hook says where the poet went instead" do
      entry =
        %{@entry | teaser: nil, title: nil, place_name: nil}
        |> Map.put(:excursion, %{topic: %{label: "Kit airplanes"}})

      assert Notifier.publish_text(@poet, entry, 3, "L") =~
               "Day 3 · Nam: an excursion into Kit airplanes"
    end

    test "a private poet's link goes to the owner's journal for that date" do
      assert Notifier.entry_link(%{@poet | is_public: false}, @entry)
             |> String.ends_with?("/journal/2026-09-11")
    end
  end

  describe "web push" do
    test "title carries the day and place, body the teaser" do
      payload = WebPush.entry_payload(@poet, @entry, 17)

      assert payload.title == "Day 17 · Nam in Cordoba"
      assert payload.body == @entry.teaser
      assert payload.url == "/journal/2026-09-11"
      assert payload.tag == "entry-7"
    end

    test "falls back to the poet's current place and the title" do
      payload = WebPush.entry_payload(@poet, %{@entry | place_name: nil, teaser: nil}, 2)
      assert payload.title == "Day 2 · Nam in Lisbon"
      assert payload.body == "The rooftop nobody mentions"

      bare =
        WebPush.entry_payload(
          %{@poet | current_place_name: nil},
          %{@entry | place_name: nil, teaser: nil, title: nil},
          2
        )

      assert bare.title == "Day 2 · Nam"
      assert bare.body == "A new journal entry is waiting."
    end

    test "an excursion's title names the topic, not the place the poet is parked in" do
      entry =
        %{@entry | place_name: nil}
        |> Map.put(:excursion, %{topic: %{label: "Kit airplanes"}})

      payload = WebPush.entry_payload(@poet, entry, 5)
      assert payload.title == "Day 5 · Nam, an excursion into Kit airplanes"
      assert payload.body == @entry.teaser
    end
  end

  describe "book ready" do
    test "names the poet and links straight to the book" do
      assert Notifier.book_ready_text(@poet, "https://poet.travel/journal/book") ==
               "📖 Nam has finished composing your book.\nhttps://poet.travel/journal/book"
    end
  end
end
