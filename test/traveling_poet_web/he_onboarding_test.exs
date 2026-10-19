defmodule TravelingPoetWeb.HeOnboardingTest do
  @moduledoc "A Hebrew reader sets up their poet in Hebrew (card-101)."
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Topics.Topic
  alias TravelingPoetWeb.ProductTour

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "every step of the wizard is in Hebrew", %{conn: conn} do
    user = user_fixture(%{locale: "he"})
    {:ok, view, html} = live(sign_in(conn, user), ~p"/onboarding")

    assert html =~ "שלב 1 מתוך 3"
    assert html =~ "נעים להכיר"
    refute html =~ "Meet your poet"
    refute html =~ "Step 1 of 3"

    html = render_click(view, "next", %{})
    assert html =~ "לאן הדרך?"
    assert html =~ "בשביל מה אתם נוסעים?"
    assert html =~ "אוכל ושתייה"
    assert html =~ ~r/יוצאים מ-<b[^>]*>/u
    refute html =~ "Food &amp; drink"
    refute html =~ "Where are they headed?"

    render_click(view, "toggle_passion", %{"domain" => "food"})
    html = render_click(view, "next", %{})
    assert html =~ "מוכנים לצאת לדרך"
    assert html =~ "גלויות על:"
    assert html =~ "אוכל ושתייה"
    refute html =~ "Ready to set out"
  end

  # The interests line keeps the domain's English name; the taste itself is
  # the reader's to read in Settings, so it is saved in their language, its
  # domain the same key either way.
  test "a taste picked without words is saved in the reader's language", %{conn: conn} do
    user = user_fixture(%{locale: "he"})
    {:ok, view, _html} = live(sign_in(conn, user), ~p"/onboarding")

    render_click(view, "next", %{})
    render_click(view, "toggle_passion", %{"domain" => "food"})
    render_click(view, "next", %{})
    render_click(view, "create_poet", %{})

    poet = TravelingPoet.Poets.get_poet_by_user(user.id)
    assert "Food & drink" in poet.interests
    assert [%{label: "אוכל ושתייה", domain: "food"}] = TravelingPoet.Topics.list(poet.id)
  end

  test "domain labels and the tour follow the reader's language" do
    Gettext.with_locale(TravelingPoetWeb.Gettext, "he", fn ->
      assert Topic.domain_label("mountains") == "הרים וטיפוס"
      assert Topic.domain_name("mountains") == "Mountains & climbing"
      assert Enum.find(ProductTour.slides(), &(&1.id == "listen")).title == "האזנה לעמוד"
    end)

    assert Topic.domain_label("mountains") == "Mountains & climbing"
    assert Enum.find(ProductTour.slides(), &(&1.id == "listen")).title == "Listen to the page"
  end
end
