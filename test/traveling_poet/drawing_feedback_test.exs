defmodule TravelingPoet.DrawingFeedbackTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Illustrations, Journal, Markers}
  alias TravelingPoet.Markers.Delivery

  # A published page whose main drawing is `drawing`.
  defp drawn_page do
    user = agent_user_fixture(%{credits: 5})
    poet = poet_fixture(user)
    entry = published_entry_fixture(poet)
    drawing = media_fixture(poet, %{journal_entry_id: entry.id, prompt: "the Széchenyi bridge"})

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{kind: "description", body: "A river day."},
        %{kind: "illustration", media_id: drawing.id}
      ])

    entry = Journal.preload_entry(Journal.get_entry!(entry.id))
    {user, poet, entry, drawing}
  end

  describe "rate_drawing/4" do
    test "a drawing holds one pending rating: the same again takes it back, another replaces it" do
      {user, _poet, entry, drawing} = drawn_page()

      assert {:ok, meh} = Markers.rate_drawing(user, entry, drawing.id, "meh")
      assert meh.target == "illustration"
      assert meh.media_id == drawing.id
      assert meh.section_kind == "illustration"
      assert meh.section_position == 1

      assert {:ok, made_up} = Markers.rate_drawing(user, entry, to_string(drawing.id), "made_up")
      assert [only] = Markers.list_markers(entry.id)
      assert only.id == made_up.id

      assert {:ok, nil} = Markers.rate_drawing(user, entry, drawing.id, "made_up")
      assert Markers.list_markers(entry.id) == []
    end

    test "a rating already sent stays, and pressing again asks once more" do
      {user, _poet, entry, drawing} = drawn_page()
      {:ok, first} = Markers.rate_drawing(user, entry, drawing.id, "inaccurate")
      Markers.mark_sent([first.id])

      assert {:ok, again} = Markers.rate_drawing(user, entry, drawing.id, "inaccurate")
      assert again.id != first.id
      assert length(Markers.list_markers(entry.id)) == 2
    end

    test "only the drawing buttons, and the drawing-only kinds stay off text" do
      {user, _poet, entry, drawing} = drawn_page()

      assert {:error, :invalid} = Markers.rate_drawing(user, entry, drawing.id, "boring")
      assert {:error, :invalid} = Markers.rate_drawing(user, entry, "nope", "meh")

      assert {:error, changeset} =
               Markers.add_marker(user, entry, %{
                 "kind" => "made_up",
                 "target" => "text",
                 "quote" => "A river day",
                 "section_kind" => "description",
                 "section_position" => "0"
               })

      assert %{kind: ["is for drawings only"]} = errors_on(changeset)
    end
  end

  test "the digest asks for a redraw and quotes what the reader said is wrong" do
    {user, poet, entry, drawing} = drawn_page()
    {:ok, marker} = Markers.rate_drawing(user, entry, drawing.id, "made_up")
    {:ok, marker} = Markers.update_note(user.id, marker.id, "the bridge has no road on it")

    message = Delivery.digest_message(poet, entry, [marker], true)

    assert message =~ "- [Made up] the illustration (media #{drawing.id}) -> redraw it"
    assert message =~ ~s(Your companion added: "the bridge has no road on it")
  end

  describe "a redrawn page" do
    test "the drawing the reader rejected does not come back beside the redraw" do
      {user, poet, entry, drawing} = drawn_page()
      {:ok, _} = Markers.rate_drawing(user, entry, drawing.id, "made_up")

      redraw = media_fixture(poet, %{journal_entry_id: entry.id})

      {:ok, _} =
        Journal.replace_sections(entry, [
          %{kind: "description", body: "A river day."},
          %{kind: "illustration", media_id: redraw.id}
        ])

      entry = Journal.preload_entry(Journal.get_entry!(entry.id))
      assert Journal.unattached_illustrations(entry, entry.sections) == []
    end

    test "a drawing that was only praised still shows when no section claims it" do
      {user, _poet, entry, drawing} = drawn_page()
      {:ok, _} = Markers.rate_drawing(user, entry, drawing.id, "beautiful")

      {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: "A river day."}])
      entry = Journal.preload_entry(Journal.get_entry!(entry.id))

      assert [%{id: id}] = Journal.unattached_illustrations(entry, entry.sections)
      assert id == drawing.id
    end
  end

  test "every drawing prompt holds the model to the real place" do
    for kind <- ["illustration", "spot"] do
      assert Illustrations.style_suffix(kind) =~ "a bridge carries its deck"
    end
  end
end
