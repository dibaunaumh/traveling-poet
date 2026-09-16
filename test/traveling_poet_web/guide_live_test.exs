defmodule TravelingPoetWeb.GuideLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Guide, Poets}

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp guide_poet do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user)
    {:ok, _} = Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})
    {user, poet}
  end

  defp seed_places(poet, places, opts \\ []) do
    entry = published_entry_fixture(poet, Map.new(Keyword.take(opts, [:entry_date])))
    {:ok, saved} = Guide.replace_places(entry, places)
    saved
  end

  defp place(name, extra \\ %{}) do
    Map.merge(%{"name" => name, "category" => "restaurant"}, extra)
  end

  test "the guide is reachable from the nav for a signed-in user", %{conn: conn} do
    {user, _poet} = guide_poet()

    {:ok, _view, html} = live(signed_in(conn, user), ~p"/journal")
    assert html =~ ~s|href="/guide"|
  end

  # The mock's empty state: a new poet has nothing to guide with yet, and that
  # should read as "not yet", not as a broken page.
  test "an empty guide says it is still filling in", %{conn: conn} do
    {user, poet} = guide_poet()

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide")

    assert has_element?(view, "#guide-empty")
    assert render(view) =~ poet.name
  end

  test "places render as cards in the list view", %{conn: conn} do
    {user, poet} = guide_poet()
    seed_places(poet, [place("Tasca do Chico"), place("Miradouro", %{"category" => "viewpoint"})])

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide")

    assert has_element?(view, "#guide-list")
    refute has_element?(view, "#guide-empty")
    assert render(view) =~ "Tasca do Chico"
    assert render(view) =~ "Miradouro"
  end

  test "the view switcher moves between map, list and itinerary", %{conn: conn} do
    {user, poet} = guide_poet()
    seed_places(poet, [place("Tasca do Chico")])

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide")
    assert has_element?(view, "#guide-list")

    view |> element("#guide-view-itinerary") |> render_click()
    assert has_element?(view, "#guide-itinerary")
    assert has_element?(view, "#guide-day-1")

    view |> element("#guide-view-map") |> render_click()
    assert has_element?(view, "#guide-map")
  end

  test "filter chips narrow the list and carry their counts", %{conn: conn} do
    {user, poet} = guide_poet()

    seed_places(poet, [
      place("Ramiro"),
      place("Fado ao Castelo", %{"category" => "event"}),
      place("Miradouro", %{"category" => "viewpoint"})
    ])

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide")

    view |> element("#guide-filter-food") |> render_click()
    html = render(view)
    assert html =~ "Ramiro"
    refute html =~ "Fado ao Castelo"

    view |> element("#guide-filter-events") |> render_click()
    html = render(view)
    assert html =~ "Fado ao Castelo"
    refute html =~ "Ramiro"
  end

  test "the chosen view and filter survive in the URL", %{conn: conn} do
    {user, poet} = guide_poet()
    seed_places(poet, [place("Ramiro")])

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide?view=itinerary&filter=food")

    assert has_element?(view, "#guide-itinerary")
    assert has_element?(view, "#guide-filter-food.btn-primary")
  end

  test "a nonsense view or filter falls back instead of crashing", %{conn: conn} do
    {user, poet} = guide_poet()
    seed_places(poet, [place("Ramiro")])

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide?view=wat&filter=nope")

    assert has_element?(view, "#guide-list")
    assert has_element?(view, "#guide-filter-all.btn-primary")
  end

  # A bare "★★★★" beside a restaurant reads as a sourced review score. It is
  # the poet's own opinion and the UI has to say whose it is.
  test "a rating is always labelled as the poet's own pick", %{conn: conn} do
    {user, poet} = guide_poet()
    seed_places(poet, [place("Ramiro", %{"poet_rating" => 4})])

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide")

    assert has_element?(view, "[data-testid=poet-pick]")
    # Escaped in the rendered HTML, hence &#39; rather than a bare apostrophe.
    assert render(view) =~ "#{poet.name}&#39;s pick"
  end

  test "a place with no rating shows no stars at all", %{conn: conn} do
    {user, poet} = guide_poet()
    seed_places(poet, [place("Ramiro")])

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide")

    refute has_element?(view, "[data-testid=poet-pick]")
  end

  # Coordinates arrive asynchronously and are allowed to fail. A place with no
  # pin must still be a recommendation, and the map has to say how many it is
  # not showing.
  test "an unmapped place is still listed, and the map view says so", %{conn: conn} do
    {user, poet} = guide_poet()
    [saved] = seed_places(poet, [place("Nameless viewpoint", %{"category" => "viewpoint"})])
    {:ok, _} = Guide.mark_geocode_failed(saved)

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide?view=map")

    assert render(view) =~ "couldn&#39;t be put on the map"
    view |> element("#guide-view-list") |> render_click()
    assert render(view) =~ "Nameless viewpoint"
  end

  # A detail card left open beside a map that no longer shows its pin is a
  # small lie about what you are looking at.
  test "a selected place is dropped when the filter stops showing it", %{conn: conn} do
    {user, poet} = guide_poet()

    [ramiro, _fado] =
      seed_places(poet, [
        place("Ramiro"),
        place("Fado ao Castelo", %{"category" => "event"})
      ])

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide?view=map")

    render_hook(view, "select_place", %{"id" => ramiro.id})
    assert render(view) =~ "Ramiro"

    # Ramiro is a restaurant, so the events filter excludes it: the detail card
    # must go back to the placeholder rather than keep showing a place the map
    # no longer has a pin for.
    view |> element("#guide-filter-events") |> render_click()
    html = render(view)
    assert html =~ "Pick a pin"
    refute html =~ "Ramiro"
  end

  describe "the map is told when the data changes" do
    # The map div is phx-update="ignore" because Leaflet owns its DOM, so a
    # changed data-places attribute does NOT re-render it. Switching city used
    # to leave the previous stay's pins sitting on the map while the list and
    # itinerary updated correctly -- only the map lied.
    defp two_stays(user) do
      poet = poet_fixture(user)
      today = Date.utc_today()

      {:ok, _} = Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})
      first = published_entry_fixture(poet, %{entry_date: today})
      {:ok, [lisbon]} = Guide.replace_places(first, [place("Tasca do Chico")])

      {:ok, _} = Poets.move_to(poet, %{lat: 48.2, lng: 16.37, place_name: "Vienna, Austria"})
      second = published_entry_fixture(poet, %{entry_date: Date.add(today, 1)})

      {:ok, [vienna]} =
        Guide.replace_places(second, [place("Cafe Museum", %{"category" => "cafe"})])

      for p <- [lisbon, vienna], do: {:ok, _} = Guide.update_geocode(p, %{lat: 1.0, lng: 2.0})

      {poet, lisbon, vienna}
    end

    test "switching city pushes the new pins to the map", %{conn: conn} do
      user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
      {poet, lisbon, _vienna} = two_stays(user)

      {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide?view=map")

      stay = Enum.find(Guide.list_stays(poet.id), &(&1.place_name == "Lisbon, Portugal"))
      view |> element("#guide-stay-#{stay.id}") |> render_click()

      assert_push_event(view, "map:update", %{places: [%{id: id, name: "Tasca do Chico"}]})
      assert id == lisbon.id
    end

    test "changing the filter pushes the narrowed pins to the map", %{conn: conn} do
      user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
      {_poet, _lisbon, _vienna} = two_stays(user)

      {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide?view=map")

      view |> element("#guide-filter-events") |> render_click()
      assert_push_event(view, "map:update", %{places: []})
    end
  end

  describe "events" do
    test "an event shows its dates and answers the Events filter", %{conn: conn} do
      {user, poet} = guide_poet()
      today = Date.utc_today()

      seed_places(poet, [
        place("Vermeer at Nakanoshima", %{
          "category" => "event",
          "starts_on" => Date.add(today, -2),
          "ends_on" => Date.add(today, 20)
        }),
        place("Cafe Museum", %{"category" => "cafe"})
      ])

      {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide")

      assert has_element?(view, "[data-testid=event-dates]")

      view |> element("#guide-filter-events") |> render_click()
      html = render(view)
      assert html =~ "Vermeer at Nakanoshima"
      refute html =~ "Cafe Museum"
    end

    # The failure mode this guards is a reader travelling for a closed
    # exhibition. An event that is over stays visible -- the poet did write
    # about it -- but it must say so and it must not lead.
    test "an event that has ended is marked, and sinks below live ones", %{conn: conn} do
      {user, poet} = guide_poet()
      today = Date.utc_today()

      seed_places(poet, [
        place("Closed Show", %{"category" => "event", "ends_on" => Date.add(today, -10)}),
        place("Still Running", %{"category" => "event", "ends_on" => Date.add(today, 10)})
      ])

      {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide?filter=events")

      html = render(view)
      assert html =~ "ended"

      # Live event first, ended one after it.
      assert :binary.match(html, "Still Running") < :binary.match(html, "Closed Show")
    end

    test "a venue is never marked ended, however old the entry", %{conn: conn} do
      {user, poet} = guide_poet()
      seed_places(poet, [place("Cafe Museum", %{"category" => "cafe"})])

      {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide")

      refute has_element?(view, "[data-testid=event-dates]")
      refute render(view) =~ "ended"
    end
  end

  test "a draft entry's places never appear", %{conn: conn} do
    {user, poet} = guide_poet()
    draft = entry_fixture(poet)
    {:ok, _} = Guide.replace_places(draft, [place("Secret Bar")])

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide")

    assert has_element?(view, "#guide-empty")
    refute render(view) =~ "Secret Bar"
  end

  test "one poet's guide never shows another's places", %{conn: conn} do
    {user, _poet} = guide_poet()
    {_other_user, other_poet} = guide_poet()
    seed_places(other_poet, [place("Not yours")])

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide")

    refute render(view) =~ "Not yours"
  end

  describe "topics" do
    alias TravelingPoet.Topics

    # An excursion into `topic` on `date`, published, with its finds.
    defp excursion(poet, topic, date, venue, finds) do
      entry = published_entry_fixture(poet, %{entry_date: date, title: "Off the road"})
      x = excursion_fixture(poet, topic, entry)
      {:ok, x} = Topics.set_venue(x, %{venue_name: venue})

      for {name, kind} <- finds,
          do: find_fixture(poet, entry, %{name: name, kind: kind, poet_rating: 4})

      x
    end

    defp with_two_excursions(poet) do
      topic = topic_fixture(poet, %{label: "Embodied minds"})

      first =
        excursion(poet, topic, ~D[2026-09-10], "ECogS 2026", [
          {"Shanahan keynote", "talk"},
          {"Robot kit", "product"}
        ])

      second =
        excursion(poet, topic, ~D[2026-09-14], "Machine Consciousness 0001", [
          {"Froese reflection", "session"}
        ])

      {topic, first, second}
    end

    test "places stay the default; a topic is one tap away with its excursion count",
         %{conn: conn} do
      {user, poet} = guide_poet()
      seed_places(poet, [place("Tasca do Chico")])
      {topic, _, _} = with_two_excursions(poet)

      {:ok, view, html} = live(signed_in(conn, user), ~p"/guide")
      assert has_element?(view, "#guide-journeys")
      assert has_element?(view, "#guide-journey-places.btn-neutral")
      assert has_element?(view, "#guide-journey-topic-#{topic.id}", "Embodied minds")
      assert html =~ "Tasca do Chico"
      refute html =~ "Shanahan keynote"

      view |> element("#guide-journey-topic-#{topic.id}") |> render_click()

      assert_patch(
        view,
        ~p"/guide?#{[filter: "all", stay: poet_stay(poet), topic: topic.id, view: "list"]}"
      )

      html = render(view)
      assert html =~ "What #{poet.name} brought back from excursions into Embodied minds"
      assert html =~ "Shanahan keynote"
      assert html =~ "Froese reflection"
      refute html =~ "Tasca do Chico"
      # finds are links, not addresses: no map for a topic
      refute has_element?(view, "#guide-view-map")
      assert has_element?(view, "#guide-filter-ideas", "Talks and papers")

      view |> element("#guide-journey-places") |> render_click()
      assert render(view) =~ "Tasca do Chico"
    end

    test "venue pills and kind chips narrow the finds", %{conn: conn} do
      {user, poet} = guide_poet()
      {topic, first, _second} = with_two_excursions(poet)

      {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide?topic=#{topic.id}")
      assert has_element?(view, "#guide-venue-all.btn-secondary")
      assert has_element?(view, "#guide-venue-#{first.id}", "ECogS 2026")

      view |> element("#guide-venue-#{first.id}") |> render_click()
      html = render(view)
      assert html =~ "Shanahan keynote"
      refute html =~ "Froese reflection"

      view |> element("#guide-filter-things") |> render_click()
      html = render(view)
      assert html =~ "Robot kit"
      refute html =~ "Shanahan keynote"

      view |> element("#guide-filter-happenings") |> render_click()
      assert has_element?(view, "#guide-finds-empty")
    end

    test "the itinerary numbers the excursions and links back to each entry", %{conn: conn} do
      {user, poet} = guide_poet()
      {topic, first, second} = with_two_excursions(poet)

      {:ok, view, html} = live(signed_in(conn, user), ~p"/guide?topic=#{topic.id}&view=itinerary")
      assert has_element?(view, "#guide-excursion-#{first.id}", "Excursion 1 into Embodied minds")

      assert has_element?(
               view,
               "#guide-excursion-#{second.id}",
               "Excursion 2 into Embodied minds"
             )

      assert html =~ ~s|href="/journal/2026-09-10?spread=finds"|

      # a filter that empties one excursion keeps its number
      view |> element("#guide-filter-things") |> render_click()

      assert has_element?(
               view,
               "#guide-excursion-#{second.id}",
               "Excursion 2 into Embodied minds"
             )

      assert has_element?(view, "#guide-excursion-#{second.id}", "Nothing under this filter.")
    end

    test "a map view asked for a topic falls back to the list", %{conn: conn} do
      {user, poet} = guide_poet()
      seed_places(poet, [place("Tasca do Chico")])
      {topic, _, _} = with_two_excursions(poet)

      {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide?view=map")
      view |> element("#guide-journey-topic-#{topic.id}") |> render_click()
      assert has_element?(view, "#guide-finds")
      refute has_element?(view, "#guide-map")

      {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide?topic=#{topic.id}&view=map")
      assert has_element?(view, "#guide-finds")
    end

    test "no row at all without a topic that has a published excursion", %{conn: conn} do
      {user, poet} = guide_poet()
      seed_places(poet, [place("Tasca do Chico")])
      topic = topic_fixture(poet, %{label: "Kit airplanes"})

      # a draft excursion does not count
      draft = entry_fixture(poet, %{entry_date: ~D[2026-09-12]})
      excursion_fixture(poet, topic, draft)
      find_fixture(poet, draft, %{name: "Not yet out"})

      {:ok, view, html} = live(signed_in(conn, user), ~p"/guide?topic=#{topic.id}")
      refute has_element?(view, "#guide-journeys")
      refute html =~ "Not yet out"
      assert html =~ "Tasca do Chico"
    end

    test "a poet with excursions and no places yet can still reach them", %{conn: conn} do
      {user, poet} = guide_poet()
      {topic, _, _} = with_two_excursions(poet)

      {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide")
      assert has_element?(view, "#guide-empty")
      assert has_element?(view, "#guide-journey-topic-#{topic.id}")
    end
  end

  defp poet_stay(poet) do
    case TravelingPoet.Poets.current_path_point(poet.id) do
      nil -> nil
      point -> point.id
    end
  end

  test "a user with no poet is sent to onboarding", %{conn: conn} do
    user = user_fixture(%{onboarding_completed: true})

    assert {:error, {:live_redirect, %{to: "/onboarding"}}} =
             live(signed_in(conn, user), ~p"/guide")
  end
end
