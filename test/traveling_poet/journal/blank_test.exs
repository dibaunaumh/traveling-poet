defmodule TravelingPoet.Journal.BlankTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Journal
  alias TravelingPoet.Journal.Blank
  import Phoenix.LiveViewTest, only: [render_component: 2]

  test "placeholders a model writes for no value become nil" do
    for t <- ["null", " NULL ", "undefined", "None", "nil", "n/a", "", "   "],
        do: assert(Blank.clean(t) == nil)

    assert Blank.clean(" Nullarbor Plain ") == "Nullarbor Plain"
    assert Blank.clean(nil) == nil
    refute Blank.present?("null")
    assert Blank.present?("What I found")
  end

  test "a section titled null is stored without a title, and the page prints none" do
    poet = poet_fixture(user_fixture())
    entry = entry_fixture(poet, %{title: "null", teaser: "undefined"})
    assert entry.title == nil
    assert entry.teaser == nil

    {:ok, [desc, poem]} =
      Journal.replace_sections(entry, [
        %{kind: "description", title: "null", body: "From a porch in Nong Khiaw."},
        %{kind: "poem", title: "The festival is still two weeks away", body: "a verse"}
      ])

    assert desc.title == nil
    assert poem.title == "The festival is still two weeks away"
  end

  test "a row stored before the fix still renders without the word" do
    html =
      render_component(&TravelingPoetWeb.NotebookComponents.section/1,
        section: %{
          kind: "description",
          title: "null",
          body: "From a porch.",
          position: 0,
          media_id: nil,
          metadata: %{}
        },
        media: nil
      )

    refute html =~ "null"
    assert html =~ "From a porch."
  end
end
