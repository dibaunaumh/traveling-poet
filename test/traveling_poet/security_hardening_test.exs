defmodule TravelingPoet.SecurityHardeningTest do
  # The three holes the 2026-10-02 security review found worth fixing at once.
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Guide, Journal, Poets}
  alias TravelingPoetWeb.Api.ArtifactController

  describe "poet names (shown as map labels on public pages)" do
    test "markup and overlong names are refused" do
      poet = poet_fixture(user_fixture())

      assert {:error, cs} = Poets.update_poet(poet, %{name: "<img src=x onerror=alert(1)>"})
      assert %{name: [_]} = errors_on(cs)

      assert {:error, cs} = Poets.update_poet(poet, %{name: String.duplicate("a", 61)})
      assert %{name: [_]} = errors_on(cs)

      assert {:ok, _} = Poets.update_poet(poet, %{name: "Ezra Halloway"})
    end
  end

  describe "another poet's media" do
    setup do
      mine = poet_fixture(user_fixture())
      theirs = poet_fixture(user_fixture(), %{is_public: false})

      %{
        mine: mine,
        entry: entry_fixture(mine),
        own: media_fixture(mine),
        foreign: media_fixture(theirs)
      }
    end

    test "a section cannot point at it, and the page's drawing never resolves to it",
         %{entry: entry, own: own, foreign: foreign} do
      {:ok, sections} =
        Journal.replace_sections(entry, [
          %{"kind" => "illustration", "media_id" => foreign.id},
          %{"kind" => "illustration", "media_id" => own.id}
        ])

      assert Enum.map(sections, & &1.media_id) == [nil, own.id]
      assert Journal.entry_illustration(entry).id == own.id
    end

    test "a place cannot carry it", %{entry: entry, foreign: foreign} do
      {:ok, [place]} =
        Guide.replace_places(entry, [
          %{"name" => "Plaza", "category" => "sight", "media_id" => foreign.id}
        ])

      assert place.media_id == nil
    end
  end

  describe "files from the poet's workspace" do
    test "only formats that cannot run script open in the browser" do
      assert ArtifactController.disposition("photo.png", nil) == "inline"
      assert ArtifactController.disposition("book.pdf", nil) == "inline"

      for path <- ~w(x.html y.svg z.xhtml w.HTML v.js),
          do: assert(ArtifactController.disposition(path, nil) =~ "attachment")

      assert ArtifactController.disposition("photo.png", "1") =~ "attachment"
    end
  end
end
