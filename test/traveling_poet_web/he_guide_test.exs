defmodule TravelingPoetWeb.HeGuideTest do
  @moduledoc """
  The trip guide, Discover, calendar trips and item pages in Hebrew
  (card-101): a Hebrew reader sees the interface in Hebrew, and the poet's
  own words (names, places) stay as written.
  """
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Guide, Poets, Spaces}

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp hebrew(conn), do: put_req_header(conn, "accept-language", "he-IL,he;q=0.9")

  defp guide_poet(locale) do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil, locale: locale})
    poet = poet_fixture(user, %{name: "Wren", is_public: true, status: "active"})
    {:ok, poet} = Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})
    entry = published_entry_fixture(poet, %{place_name: "Lisbon", lat: 38.72, lng: -9.13})

    {:ok, places} =
      Guide.replace_places(entry, [
        %{"name" => "Tasca do Chico", "category" => "restaurant", "poet_rating" => 4}
      ])

    {user, poet, places}
  end

  test "the owner's guide is in Hebrew for a Hebrew reader", %{conn: conn} do
    {user, _poet, _places} = guide_poet("he")

    {:ok, _view, html} = live(signed_in(conn, user), ~p"/guide")

    assert html =~ "מדריך טיול"
    assert html =~ "הבחירה של Wren"
    assert html =~ "מסעדה"
    assert html =~ "Tasca do Chico"
    refute html =~ "Trip guide"
    refute html =~ "Wren&#39;s pick"
    refute html =~ "Restaurant"
  end

  test "an English reader's guide is unchanged", %{conn: conn} do
    {user, _poet, _places} = guide_poet("en")

    {:ok, _view, html} = live(signed_in(conn, user), ~p"/guide")

    assert html =~ "Trip guide"
    assert html =~ "Wren&#39;s pick"
    refute html =~ "מדריך טיול"
  end

  test "the public guide is in Hebrew for a Hebrew visitor", %{conn: conn} do
    {_user, poet, _places} = guide_poet("en")

    {:ok, _view, html} = live(hebrew(conn), ~p"/p/#{poet.slug}/guide")

    assert html =~ "משורר בדרכים"
    assert html =~ "יומן"
    refute html =~ "a traveling poet"
  end

  test "Discover is in Hebrew for a Hebrew visitor", %{conn: conn} do
    guide_poet("en")

    {:ok, _view, html} = live(hebrew(conn), ~p"/discover")

    assert html =~ "גילוי"
    assert html =~ "בדרכים,"
    assert html =~ "העמוד הבא"
    refute html =~ "Next page"
    refute html =~ "on the road,"
  end

  test "an item page is in Hebrew for a Hebrew visitor", %{conn: conn} do
    {_user, _poet, [place]} = guide_poet("en")
    item = Spaces.get_item(place.item_id)

    html = conn |> hebrew() |> get(~p"/items/#{item.slug}") |> html_response(200)

    assert html =~ "מציאה של Wren"
    assert html =~ "מסעדה ב-Lisbon"
    refute html =~ "Found by"
  end

  test "the calendar card is in Hebrew for a Hebrew reader", %{conn: conn} do
    {user, _poet, _places} = guide_poet("he")

    {:ok, _view, html} = live(signed_in(conn, user), ~p"/settings")

    assert html =~ ~s(id="trip-settings")
    assert html =~ "עיר הבית שלכם"
    refute html =~ "Your home city"
  end
end
