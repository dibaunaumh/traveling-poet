defmodule TravelingPoetWeb.JournalMarkersTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Journal, Markers}

  @body "Steep streets and tiled walls."

  defp owner(conn, poet_attrs \\ %{}) do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user, poet_attrs)

    {:ok, entry} =
      Journal.upsert_entry(poet.id, ~D[2026-09-01], %{title: "A day", place_name: "Lisbon"})

    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: @body}])
    {:ok, entry} = Journal.publish_entry(entry)
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {conn, user, poet, entry}
  end

  defp text_payload(attrs \\ %{}) do
    Map.merge(
      %{
        "kind" => "boring",
        "target" => "text",
        "quote" => "tiled walls",
        "prefix" => "Steep streets and ",
        "suffix" => ".",
        "section_kind" => "description",
        "section_position" => "0"
      },
      attrs
    )
  end

  test "the owner's journal carries the tray, the hook, and anchored sections", %{conn: conn} do
    {conn, _user, entry, _} = owner(conn) |> then(fn {c, u, _p, e} -> {c, u, e, nil} end)
    {:ok, _view, html} = live(conn, ~p"/journal")

    assert html =~ ~s(phx-hook="Markers")
    assert html =~ ~s(id="marker-menu")
    assert html =~ "Mark what you want to change"
    assert html =~ "Select a marker &amp; highlight text to provide feedback to the poet"
    assert length(Regex.scan(~r/marker-menu-item marker-[a-z_]+"/, html)) == 7
    assert html =~ ~s(id="section-#{entry.id}-0")
    assert html =~ ~s(data-section-kind="description")
    assert html =~ ~s(data-section-position="0")
  end

  test "picking a marker toggles it; an unknown kind clears it", %{conn: conn} do
    {conn, _, _, _} = owner(conn)
    {:ok, view, _html} = live(conn, ~p"/journal")

    assert render_click(view, "pick_marker", %{"kind" => "boring"}) =~
             ~s(data-active-marker="boring")

    refute render_click(view, "pick_marker", %{"kind" => "boring"}) =~ "data-active-marker=\""

    html = render_click(view, "pick_marker", %{"kind" => "beautiful"})
    assert html =~ "Put the marker down"
    assert html =~ "to mark it Beautiful"
    refute render_click(view, "pick_marker", %{"kind" => "none"}) =~ "data-active-marker=\""
  end

  test "a text selection becomes a marker the page carries", %{conn: conn} do
    {conn, _user, _poet, entry} = owner(conn)
    {:ok, view, _html} = live(conn, ~p"/journal")

    html = render_hook(view, "marker_add", text_payload())

    assert [marker] = Markers.list_markers(entry.id)
    assert marker.kind == "boring"
    assert marker.quote == "tiled walls"
    assert marker.section_position == 0
    assert html =~ "data-markers="
    assert html =~ "tiled walls"

    html = render_hook(view, "marker_remove", %{"id" => to_string(marker.id)})
    assert Markers.list_markers(entry.id) == []
    refute html =~ "tiled walls\""
  end

  test "an illustration gets its own marker", %{conn: conn} do
    {conn, _user, poet, entry} = owner(conn)
    media = media_fixture(poet, %{journal_entry_id: entry.id})
    {:ok, view, html} = live(conn, ~p"/journal")

    assert html =~ ~s(data-media-id="#{media.id}")

    render_hook(view, "marker_add", %{
      "kind" => "drawing_needed",
      "target" => "illustration",
      "section_kind" => "illustration",
      "media_id" => to_string(media.id)
    })

    assert [%{target: "illustration", media_id: media_id}] = Markers.list_markers(entry.id)
    assert media_id == media.id
  end

  test "a malformed payload is ignored", %{conn: conn} do
    {conn, _user, _poet, entry} = owner(conn)
    {:ok, view, _html} = live(conn, ~p"/journal")

    render_hook(view, "marker_add", text_payload(%{"kind" => "meh"}))
    render_hook(view, "marker_add", %{"target" => "text"})
    assert Markers.list_markers(entry.id) == []
  end

  test "a revision keeps the reader on the same entry and says so", %{conn: conn} do
    {conn, _user, poet, entry} = owner(conn)
    {:ok, view, _html} = live(conn, ~p"/journal")

    {:ok, _} =
      Journal.replace_sections(entry, [%{kind: "description", body: "Steep streets, rewritten."}])

    send(view.pid, {:journal_revised, entry.id})
    html = render(view)

    assert html =~ "#{poet.name} revised this entry."
    assert html =~ "Steep streets, rewritten."
  end

  test "the public journal has no tray", %{conn: conn} do
    {conn, _user, poet, _entry} = owner(conn, %{is_public: true})
    {:ok, _view, html} = live(conn, ~p"/p/#{poet.slug}")

    refute html =~ "marker-menu"
    refute html =~ ~s(phx-hook="Markers")
  end
end
