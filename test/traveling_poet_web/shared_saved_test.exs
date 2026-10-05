defmodule TravelingPoetWeb.SharedSavedTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Bookmarks

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  setup do
    owner = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil, name: "Maya Levi"})
    poet = poet_fixture(owner)
    entry = published_entry_fixture(poet)

    cafe =
      place_fixture(poet, entry, %{
        name: "Charlotte",
        category: "cafe",
        lat: 50.0646,
        lng: 19.9358
      })

    {:ok, _} = Bookmarks.toggle(owner.id, "place", cafe.id)
    %{owner: owner}
  end

  test "the owner shares the list, a friend opens it without an account, and stopping kills it",
       %{conn: conn, owner: owner} do
    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/guide?saved=1")

    view |> element("#share-saved-start") |> render_click()
    token = TravelingPoet.Repo.reload!(owner).saved_share_token
    assert is_binary(token)
    assert has_element?(view, ~s(#share-saved-link[href="/shared/#{token}"]))

    {:ok, shared, html} = live(build_conn(), ~p"/shared/#{token}")
    assert html =~ "Maya&#39;s saved places"
    refute html =~ "Levi"
    assert has_element?(shared, "#shared-places", "Charlotte")
    assert has_element?(shared, "#plan-day-1")
    assert has_element?(shared, ~s(#shared-to-maps a[href="/shared/#{token}/places.kml"]))

    kml = build_conn() |> get(~p"/shared/#{token}/places.kml") |> response(200)
    assert kml =~ "<name>Charlotte</name>"

    view |> element("#share-saved-stop") |> render_click()
    assert {:error, {:live_redirect, %{to: "/"}}} = live(build_conn(), ~p"/shared/#{token}")
    assert build_conn() |> get(~p"/shared/#{token}/places.kml") |> response(404)
  end

  test "a made-up token finds nothing", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/shared/not-a-real-token-at-all")
    assert Bookmarks.shared_by("short") == nil
  end
end
