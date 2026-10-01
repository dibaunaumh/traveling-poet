defmodule TravelingPoetWeb.BookmarksLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Bookmarks, Guide}

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  setup do
    reader = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    own = poet_fixture(reader, %{name: "Nam"})
    own_entry = published_entry_fixture(own, %{entry_date: ~D[2026-09-27]})

    {:ok, [cafe]} =
      Guide.replace_places(own_entry, [
        %{"name" => "Cafe A Brasileira", "category" => "restaurant"}
      ])

    other = poet_fixture(user_fixture(), %{name: "Hilma", is_public: true, status: "active"})
    other_entry = published_entry_fixture(other, %{entry_date: ~D[2026-09-28]})

    {:ok, [inn]} =
      Guide.replace_places(other_entry, [%{"name" => "Tsuruya", "category" => "sight"}])

    %{reader: reader, own: own, cafe: cafe, other: other, inn: inn}
  end

  test "save a place from your own guide, and it waits under Saved",
       %{conn: conn, reader: reader, cafe: cafe} do
    {:ok, view, html} = live(signed_in(conn, reader), ~p"/guide")
    assert html =~ ~s(id="save-place-#{cafe.id}")
    refute html =~ ~s(id="guide-journey-saved")

    html = view |> element("#save-place-#{cafe.id}") |> render_click()
    assert html =~ ~s(aria-pressed="true")
    assert html =~ ~s(id="guide-journey-saved")

    {:ok, _view, html} = live(signed_in(conn, reader), ~p"/guide?saved=1")
    assert html =~ ~s(id="guide-saved")
    assert html =~ "Cafe A Brasileira"
    assert html =~ "From your journal"
  end

  test "a place saved from another poet's public guide shows under Saved with its source",
       %{conn: conn, reader: reader, other: other, inn: inn} do
    {:ok, view, _} = live(signed_in(conn, reader), ~p"/p/#{other.slug}/guide")
    view |> element("#save-place-#{inn.id}") |> render_click()
    assert Bookmarks.count(reader.id) == 1

    {:ok, view, html} = live(signed_in(conn, reader), ~p"/guide?saved=1")
    assert html =~ "Tsuruya"
    assert html =~ "From Hilma&#39;s journal"
    assert html =~ ~s(href="/p/#{other.slug}/2026-09-28")

    # unsaving from the Saved view drops the card
    html = view |> element("#save-place-#{inn.id}") |> render_click()
    refute html =~ "Tsuruya"
    assert html =~ "Nothing saved"
  end

  test "signed out, a public guide has no Save buttons", %{conn: conn, other: other, inn: inn} do
    {:ok, _view, html} = live(conn, ~p"/p/#{other.slug}/guide")
    assert html =~ "Tsuruya"
    refute html =~ ~s(id="save-place-#{inn.id}")
  end

  test "Discover's place card can be saved", %{conn: conn, reader: reader, inn: inn} do
    {:ok, view, _} = live(signed_in(conn, reader), ~p"/discover")
    render_hook(view, "select", %{"kind" => "place", "id" => to_string(inn.id), "from" => "map"})
    view |> element("#save-place-#{inn.id}") |> render_click()
    assert Bookmarks.saved?(Bookmarks.keys(reader.id), inn)
  end

  test "Saved is the owner's own: a public guide ignores ?saved=1",
       %{conn: conn, reader: reader, other: other, inn: inn} do
    {:ok, :saved} = Bookmarks.toggle(reader.id, "place", inn.id)
    {:ok, _view, html} = live(signed_in(conn, reader), ~p"/p/#{other.slug}/guide?saved=1")
    refute html =~ ~s(id="guide-saved")
  end

  # Udi on card-70: save from the journal's Places view, not only the guide.
  describe "the journal's Places spread" do
    test "your own journal saves a stop", %{conn: conn, reader: reader, cafe: cafe} do
      {:ok, view, html} = live(signed_in(conn, reader), ~p"/journal/2026-09-27?spread=places")
      assert html =~ ~s(id="stop-#{cafe.id}")

      html = view |> element("#stop-#{cafe.id} #save-place-#{cafe.id}") |> render_click()
      assert html =~ ~s(aria-pressed="true")
      assert Bookmarks.saved?(Bookmarks.keys(reader.id), cafe)
    end

    test "another poet's public journal saves a stop when signed in, and offers none signed out",
         %{conn: conn, reader: reader, other: other, inn: inn} do
      {:ok, view, _} =
        live(signed_in(conn, reader), ~p"/p/#{other.slug}/2026-09-28?spread=places")

      view |> element("#stop-#{inn.id} #save-place-#{inn.id}") |> render_click()
      assert Bookmarks.saved?(Bookmarks.keys(reader.id), inn)

      {:ok, _view, html} = live(build_conn(), ~p"/p/#{other.slug}/2026-09-28?spread=places")
      assert html =~ ~s(id="stop-#{inn.id}")
      refute html =~ ~s(id="save-place-#{inn.id}")
    end
  end
end
