defmodule TravelingPoetWeb.JournalMapTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Journal

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp publish(poet, date, place, lat, lng) do
    {:ok, entry} =
      Journal.upsert_entry(poet.id, date, %{
        title: place,
        place_name: place,
        lat: lat,
        lng: lng
      })

    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: "a day"}])
    {:ok, published} = Journal.publish_entry(entry)
    published
  end

  defp two_entries do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user)
    publish(poet, ~D[2026-08-25], "Lisbon, Portugal", 38.72, -9.13)
    publish(poet, ~D[2026-08-26], "Seville, Spain", 37.39, -5.99)
    {user, poet}
  end

  # The map only ever knew the poet's path and where it is NOW, and the div is
  # phx-update="ignore" so a changed data-points attribute would not have
  # re-rendered it anyway. Paging back through the journal left the map sitting
  # on the current city while the page talked about somewhere else.
  # Entry nav uses <.link navigate=...>, so it remounts rather than patching.
  # The rendered data-points must therefore already carry the right focus --
  # and it must, because phx-update="ignore" means LiveView will not touch that
  # attribute on an element whose id it has already seen.
  test "each entry renders the map focused on its own place", %{conn: conn} do
    {user, _poet} = two_entries()

    {:ok, _view, newest} = live(signed_in(conn, user), ~p"/journal")
    assert newest =~ "Seville, Spain"
    assert focus_from(newest)["name"] == "Seville, Spain"

    {:ok, _view, earlier} = live(signed_in(conn, user), ~p"/journal/2026-08-25")
    assert focus_from(earlier)["name"] == "Lisbon, Portugal"
    assert focus_from(earlier)["lat"] == 38.72
  end

  test "paging pushes the new focus for the patch path too", %{conn: conn} do
    {user, _poet} = two_entries()

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/journal")
    assert_push_event(view, "map:update", %{focus: %{name: "Seville, Spain"}})

    {:ok, view2, _html} = live(signed_in(conn, user), ~p"/journal/2026-08-25")
    assert_push_event(view2, "map:update", %{focus: %{name: "Lisbon, Portugal"}})
  end

  defp focus_from(html) do
    [_, encoded] = Regex.run(~r/data-points="([^"]*)"/, html)

    encoded
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
    |> Jason.decode!()
    |> Map.get("focus")
  end

  test "the focus carries the entry's date, so the pin can name the day", %{conn: conn} do
    {user, _poet} = two_entries()

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/journal/2026-08-25")

    assert_push_event(view, "map:update", %{focus: %{date: "2026-08-25"}})
  end

  # An entry the poet never gave coordinates for must not blank the map or
  # crash the payload; it simply has nothing to focus on.
  test "an entry with no coordinates focuses nothing", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user)
    publish(poet, ~D[2026-08-25], "Somewhere", nil, nil)

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/journal")

    assert_push_event(view, "map:update", %{focus: nil})
  end

  test "the public journal follows the entry too", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user, %{is_public: true, slug: "mapper"})
    publish(poet, ~D[2026-08-25], "Lisbon, Portugal", 38.72, -9.13)
    publish(poet, ~D[2026-08-26], "Seville, Spain", 37.39, -5.99)

    {:ok, view, _html} = live(conn, ~p"/p/mapper/2026-08-25")

    assert_push_event(view, "map:update", %{focus: %{name: "Lisbon, Portugal"}})
  end
end
