defmodule TravelingPoetWeb.DiscoverLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Poets

  defp public_poet(name) do
    poet = poet_fixture(user_fixture(), %{name: name, is_public: true, status: "active"})
    {:ok, poet} = Poets.move_to(poet, %{lat: 41.15, lng: -8.61, place_name: "Porto"})
    poet
  end

  test "anyone can look around: the map, and the newest page open beside it", %{conn: conn} do
    wren = public_poet("Wren")

    older =
      published_entry_fixture(wren, %{
        entry_date: ~D[2026-09-01],
        title: "Tiles",
        lat: 41.1,
        lng: -8.6
      })

    newest =
      published_entry_fixture(wren, %{
        entry_date: ~D[2026-09-02],
        title: "Fado at night",
        teaser: "A voice in an alley.",
        lat: 41.1,
        lng: -8.6
      })

    {:ok, view, html} = live(conn, ~p"/discover")

    assert html =~ "Discover"
    assert has_element?(view, "#discover-map[phx-hook=DiscoverMap]")
    assert has_element?(view, "#discover-entry-#{newest.id}", "Fado at night")
    assert html =~ "A voice in an alley."
    assert has_element?(view, ~s|a[href="/p/#{wren.slug}/2026-09-02"]|, "Read this page")

    # The map picks another page.
    render_hook(view, "select", %{"kind" => "entry", "id" => older.id, "from" => "map"})
    assert has_element?(view, "#discover-entry-#{older.id}", "Tiles")
  end

  test "a place opens with its poet's pick and a way into that poet's guide", %{conn: conn} do
    wren = public_poet("Wren")
    entry = published_entry_fixture(wren, %{lat: 41.1, lng: -8.6})

    place =
      place_fixture(wren, entry, %{name: "Casa Guedes", lat: 41.15, lng: -8.6, poet_rating: 4})

    {:ok, view, _html} = live(conn, ~p"/discover")

    render_hook(view, "select", %{"kind" => "place", "id" => to_string(place.id), "from" => "map"})

    assert has_element?(view, "#discover-place-#{place.id}", "Casa Guedes")
    assert has_element?(view, "[data-testid=poet-pick]", "Wren's pick")

    assert has_element?(
             view,
             ~s|a[href^="/p/#{wren.slug}/guide?"][href*="view=map"][href*="place=#{place.id}"]|,
             "Open in Wren"
           )
  end

  test "a poet's name under a page opens the poet and tells the map where to look",
       %{conn: conn} do
    wren = public_poet("Wren")
    published_entry_fixture(wren, %{lat: 41.1, lng: -8.6})

    {:ok, view, _html} = live(conn, ~p"/discover")
    view |> element("button", "More about Wren") |> render_click()

    assert has_element?(view, "#discover-poet-#{wren.slug}", "now in Porto")
    assert_push_event(view, "discover:focus", %{kind: "poet", id: slug})
    assert slug == wren.slug
  end

  test "a private poet's page cannot be asked for", %{conn: conn} do
    hidden = poet_fixture(user_fixture(), %{name: "Hilda", is_public: false, status: "active"})
    entry = published_entry_fixture(hidden, %{title: "Secret", lat: 1.0, lng: 1.0})

    {:ok, view, html} = live(conn, ~p"/discover")
    refute html =~ "Hilda"

    render_hook(view, "select", %{"kind" => "entry", "id" => entry.id})
    refute render(view) =~ "Secret"
  end

  test "a publish anywhere reaches the map", %{conn: conn} do
    wren = public_poet("Wren")
    {:ok, view, _html} = live(conn, ~p"/discover")

    entry = published_entry_fixture(wren, %{title: "New page", lat: 41.1, lng: -8.6})
    send(view.pid, {:journal_published, wren.id, entry.id})

    assert_push_event(view, "discover:update", %{entries: [%{title: "New page"}]})
  end

  # The toggles' state lives in the hook; a re-render must not reset them.
  test "the layer toggles survive the overview changing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover")
    assert has_element?(view, "#discover-layers[phx-update=ignore] [data-layer=places]")
  end

  test "Discover is in the header for everyone", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/discover")
    assert html =~ ~s|href="/discover"|
  end
end
