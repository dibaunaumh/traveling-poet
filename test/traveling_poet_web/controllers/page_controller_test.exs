defmodule TravelingPoetWeb.PageControllerTest do
  use TravelingPoetWeb.ConnCase

  import TravelingPoet.Fixtures

  test "GET / signed out shows the hero and sign-up CTAs", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "Your personal travel scout."
    assert html =~ "Start exploring"
    assert html =~ "Send out your poet"
    # no poets yet: the empty-state line, not a "0 poets" count
    assert html =~ "still lacing their boots"
    refute html =~ "0 poets exploring"
  end

  test "GET / map data carries avatar and a link to the latest published entry", %{conn: conn} do
    user = user_fixture()

    poet =
      poet_fixture(user, %{
        name: "Marta",
        is_public: true,
        status: "active",
        avatar_url: "/media/abc123"
      })

    {:ok, entry} =
      TravelingPoet.Journal.upsert_entry(poet.id, ~D[2026-08-20], %{title: "Older"})

    {:ok, _} = TravelingPoet.Journal.publish_entry(entry)

    {:ok, newest} =
      TravelingPoet.Journal.upsert_entry(poet.id, ~D[2026-08-27], %{title: "Newest"})

    {:ok, _} = TravelingPoet.Journal.publish_entry(newest)

    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "/media/abc123"
    assert html =~ "/p/#{poet.slug}/2026-08-27"
    assert html =~ "1 poet exploring the world"
  end

  test "GET / signed in hides sign-up CTAs and links to the journal", %{conn: conn} do
    user = user_fixture()
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "Open your journal"
    refute html =~ "Send out your poet"
    refute html =~ "Scout a trip"
    refute html =~ "/auth/google"
  end
end
