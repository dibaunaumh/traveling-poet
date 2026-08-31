defmodule TravelingPoetWeb.LearnedProfileTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Poets, Preferences}

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp poet_with(user, prefs) do
    poet = poet_fixture(user, %{name: "Wren"})
    for attrs <- prefs, do: {:ok, _} = Preferences.record(poet.id, attrs)
    poet
  end

  test "the panel shows what was learned, and where it came from", %{conn: conn} do
    user = user_fixture(%{onboarding_completed: true})

    poet_with(user, [
      %{
        label: "american stupid things",
        dimension: "topic",
        source: "chat",
        evidence: %{"quote" => "look for american stupid things"}
      },
      %{label: "long entries", dimension: "length", polarity: "avoid", source: "tap"}
    ])

    {:ok, _view, html} = live(sign_in(conn, user), ~p"/settings")

    assert html =~ "What Wren has learned about you"
    assert html =~ "american stupid things"
    # provenance is shown, including the user's own words — nothing is secret
    assert html =~ "you said this in chat"
    assert html =~ "look for american stupid things"
    # a negative preference reads as one
    assert html =~ "less:"
  end

  test "removing a preference moves it out of the poet's reach, and back", %{conn: conn} do
    user = user_fixture(%{onboarding_completed: true})
    poet = poet_with(user, [%{label: "more museums", dimension: "topic", source: "tap"}])

    {:ok, view, _html} = live(sign_in(conn, user), ~p"/settings")

    [pref] = Preferences.list_active(poet.id)
    html = render_click(view, "dismiss_preference", %{"id" => to_string(pref.id)})

    assert Preferences.list_active(poet.id) == []
    assert Preferences.profile_payload(poet.id) == []
    assert html =~ "Removed (1)"

    html = render_click(view, "restore_preference", %{"id" => to_string(pref.id)})
    assert [restored] = Preferences.list_active(poet.id)
    assert restored.label == "more museums"
    assert html =~ "more museums"
  end

  test "interests are finally editable, and reach the agent's context", %{conn: conn} do
    user = user_fixture(%{onboarding_completed: true})
    poet = poet_fixture(user, %{name: "Wren", interests: ["bridges"]})

    {:ok, view, html} = live(sign_in(conn, user), ~p"/settings")
    assert html =~ "What Wren to look for" or html =~ "look for"
    assert html =~ "bridges"

    render_change(view, "save_poet", %{
      "personality" => poet.personality,
      "interests" => "street food, brutalist architecture",
      "stay_duration_days" => "3",
      "verbosity" => "balanced"
    })

    updated = Poets.get_poet_by_user(user.id)
    # the column is what get_poet_context serves the agent every run
    assert updated.interests == ["street food", "brutalist architecture"]
    # ...and the settings copy is kept in step for the next workspace bake
    assert updated.settings["user_interests"] == ["street food", "brutalist architecture"]
  end

  test "an empty profile says so plainly", %{conn: conn} do
    user = user_fixture(%{onboarding_completed: true})
    _poet = poet_fixture(user, %{name: "Wren"})

    {:ok, _view, html} = live(sign_in(conn, user), ~p"/settings")
    assert html =~ "Nothing yet."
  end
end
