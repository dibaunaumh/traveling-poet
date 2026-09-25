defmodule TravelingPoetWeb.PublicGuideLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Guide, Poets}

  defp public_poet(attrs \\ %{}) do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})

    poet =
      poet_fixture(
        user,
        Map.merge(%{is_public: true, slug: "wren-#{System.unique_integer([:positive])}"}, attrs)
      )

    {:ok, _} = Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})
    {user, poet}
  end

  defp place(name, extra \\ %{}) do
    Map.merge(%{"name" => name, "category" => "restaurant"}, extra)
  end

  defp seed(poet, places) do
    entry = published_entry_fixture(poet)
    {:ok, saved} = Guide.replace_places(entry, places)
    saved
  end

  test "the public journal and guide carry no World map or Guide buttons of their own",
       %{conn: conn} do
    # Discover and Guide are in the site's own menu now; the old buttons
    # pointed "World map" at a home page that no longer is one.
    {_user, poet} = public_poet()
    seed(poet, [place("Tasca do Chico")])

    {:ok, journal, _html} = live(conn, ~p"/p/#{poet.slug}")
    refute render(journal) =~ "World map"
    refute has_element?(journal, ~s(main a.btn[href="/p/#{poet.slug}/guide"]))

    {:ok, guide, _html} = live(conn, ~p"/p/#{poet.slug}/guide")
    refute render(guide) =~ "World map"
    # the way back to the poet's journal stays
    assert has_element?(guide, ~s(a[href="/p/#{poet.slug}"]), "Journal")
  end

  test "a public poet's guide is readable by anyone, signed out", %{conn: conn} do
    {_user, poet} = public_poet()
    seed(poet, [place("Tasca do Chico"), place("Miradouro", %{"category" => "viewpoint"})])

    {:ok, view, _html} = live(conn, ~p"/p/#{poet.slug}/guide")

    assert has_element?(view, "#guide-list")
    assert render(view) =~ "Tasca do Chico"
    assert render(view) =~ "Miradouro"
  end

  # Discover links a place straight to its card on the map.
  test "?place= opens the guide on that place", %{conn: conn} do
    {_user, poet} = public_poet()

    [_tasca, miradouro] =
      seed(poet, [
        place("Tasca do Chico", %{"lat" => 38.71, "lng" => -9.14}),
        place("Miradouro", %{"category" => "viewpoint", "lat" => 38.72, "lng" => -9.13})
      ])

    {:ok, view, _html} = live(conn, ~p"/p/#{poet.slug}/guide?view=map&place=#{miradouro.id}")
    assert has_element?(view, "#place-#{miradouro.id}", "Miradouro")

    {:ok, view, _html} = live(conn, ~p"/p/#{poet.slug}/guide?view=map&place=nonsense")
    refute has_element?(view, "[id^=place-]")
  end

  # Same gate the public journal uses. A private poet's recommendations are as
  # private as its prose.
  test "a private poet's guide is not reachable", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user, %{is_public: false, slug: "hidden-poet"})
    seed(poet, [place("Secret Bar")])

    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/p/#{poet.slug}/guide")
  end

  test "an unknown slug redirects home rather than erroring", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/p/no-such-poet/guide")
  end

  # published_only is the default in list_places/2, so this holds for the
  # public view without the public view having to remember it.
  test "a draft entry's places never reach the public guide", %{conn: conn} do
    {_user, poet} = public_poet()
    draft = entry_fixture(poet)
    {:ok, _} = Guide.replace_places(draft, [place("Unpublished Bar")])

    {:ok, view, _html} = live(conn, ~p"/p/#{poet.slug}/guide")

    assert has_element?(view, "#guide-empty")
    refute render(view) =~ "Unpublished Bar"
  end

  test "the guide and journal link to each other", %{conn: conn} do
    {_user, poet} = public_poet()
    # the journal reaches the guide through a page's places, which is all
    # the guide has to show
    seed(poet, [place("Tasca do Chico")])
    entry_date = Date.to_iso8601(Date.utc_today())

    {:ok, _view, journal} = live(conn, ~p"/p/#{poet.slug}/#{entry_date}?spread=places")
    assert journal =~ ~s|href="/p/#{poet.slug}/guide|

    {:ok, _view, guide} = live(conn, ~p"/p/#{poet.slug}/guide")
    assert guide =~ ~s|href="/p/#{poet.slug}"|
  end

  # "guide" must not be parsed as a date by the /p/:slug/:date route.
  test "the guide route is not swallowed by the dated journal route", %{conn: conn} do
    {_user, poet} = public_poet()
    seed(poet, [place("Tasca do Chico")])

    {:ok, view, _html} = live(conn, ~p"/p/#{poet.slug}/guide")
    assert has_element?(view, "#guide-views")
  end

  test "views and filters work the same as the owner's guide", %{conn: conn} do
    {_user, poet} = public_poet()

    seed(poet, [
      place("Ramiro"),
      place("Fado ao Castelo", %{"category" => "event"})
    ])

    {:ok, view, _html} = live(conn, ~p"/p/#{poet.slug}/guide")

    view |> element("#guide-filter-events") |> render_click()
    html = render(view)
    assert html =~ "Fado ao Castelo"
    refute html =~ "Ramiro"

    view |> element("#guide-view-itinerary") |> render_click()
    assert has_element?(view, "#guide-day-1")
  end

  test "a rating is labelled as the poet's own pick here too", %{conn: conn} do
    {_user, poet} = public_poet()
    seed(poet, [place("Ramiro", %{"poet_rating" => 5})])

    {:ok, view, _html} = live(conn, ~p"/p/#{poet.slug}/guide")

    assert has_element?(view, "[data-testid=poet-pick]")
    assert render(view) =~ "#{poet.name}&#39;s pick"
  end

  # The owner's guide lists the companion's topics; a public page must not.
  test "a public guide never lists topics or finds, even when asked by URL", %{conn: conn} do
    {_user, poet} = public_poet()
    seed(poet, [place("Tasca do Chico")])
    topic = topic_fixture(poet, %{label: "Embodied minds"})
    entry = published_entry_fixture(poet, %{entry_date: ~D[2026-09-10]})
    excursion_fixture(poet, topic, entry)
    find_fixture(poet, entry, %{name: "Shanahan keynote"})

    {:ok, view, html} = live(conn, ~p"/p/#{poet.slug}/guide?topic=#{topic.id}")
    refute has_element?(view, "#guide-journeys")
    refute html =~ "Embodied minds"
    refute html =~ "Shanahan keynote"
    assert html =~ "Tasca do Chico"
  end

  test "one public poet's guide never shows another's places", %{conn: conn} do
    {_user, poet} = public_poet()
    {_other_user, other} = public_poet()
    seed(other, [place("Not yours")])
    seed(poet, [place("Mine")])

    {:ok, view, _html} = live(conn, ~p"/p/#{poet.slug}/guide")

    assert render(view) =~ "Mine"
    refute render(view) =~ "Not yours"
  end
end
