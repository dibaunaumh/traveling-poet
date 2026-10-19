defmodule TravelingPoetWeb.HeSettingsTest do
  @moduledoc "Settings for a Hebrew reader (card-101): the whole page in Hebrew."
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Affinity.Layout
  alias TravelingPoetWeb.AffinityComponents

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "a Hebrew reader sees Settings in Hebrew", %{conn: conn} do
    user = user_fixture(%{credits: 12, onboarding_completed: true, locale: "he"})
    poet = poet_fixture(user, %{name: "Wren"})

    {:ok, _view, html} = live(sign_in(conn, user), ~p"/settings")

    for hebrew <- [
          "הגדרות",
          "השינויים נשמרים אוטומטית.",
          "האופי של Wren",
          "≈ 12 ימים של מסע בקצב הנוכחי.",
          "300 קרדיטים",
          "נושאים במעקב של Wren בשבילכם",
          "מחיקת החשבון לצמיתות"
        ] do
      assert html =~ hebrew
    end

    for english <- [
          "Changes save automatically.",
          "#{poet.name}'s personality",
          "days of travel at your poet's pace",
          "300 credits",
          "Topics Wren follows for you",
          "Delete my account for good"
        ] do
      refute html =~ english
    end
  end

  test "an English reader still sees English", %{conn: conn} do
    user = user_fixture(%{credits: 12, onboarding_completed: true})
    _poet = poet_fixture(user, %{name: "Wren"})

    {:ok, _view, html} = live(sign_in(conn, user), ~p"/settings")
    assert html =~ "Changes save automatically."
    assert html =~ "Topics Wren follows for you"
    assert html =~ "≈ 12 days of travel at your poet&#39;s pace."
    refute html =~ "הגדרות"
  end

  test "the taste map's legend is in Hebrew" do
    %{points: points} = Layout.layout()
    path = points |> Map.keys() |> hd()
    profile = [%{path: path, names: ["Art", "Painting", "Murals"], score: 2.0}]

    html =
      Gettext.with_locale(TravelingPoetWeb.Gettext, "he", fn ->
        render_component(&AffinityComponents.taste_map/1, profile: profile)
      end)

    assert html =~ "נמשכים"
    assert html =~ "Murals (Art): נמשכים"
    refute html =~ "leaning toward"
  end
end
