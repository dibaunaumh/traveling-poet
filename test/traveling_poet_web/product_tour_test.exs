defmodule TravelingPoetWeb.ProductTourTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoetWeb.ProductTour

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp publish(poet, title) do
    entry = entry_fixture(poet, %{title: title})
    {:ok, entry} = TravelingPoet.Journal.publish_entry(entry)
    entry
  end

  test "every slide has a title, a why and a how, in plain copy" do
    slides = ProductTour.slides()
    assert length(slides) >= 12

    for slide <- slides, field <- [:title, :why, :how] do
      text = Map.fetch!(slide, field)
      assert is_binary(text) and text != ""
      refute text =~ "—", "no em dashes in UI copy: #{slide.id}.#{field}"
    end

    assert slides |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(slides)
  end

  describe "while the first page is on its way" do
    test "the tour leads the wait while the poet is being set up", %{conn: conn} do
      user = user_fixture(%{onboarding_completed: true, sprite_provisioned: false})
      poet = poet_fixture(user)

      {:ok, view, html} = live(signed_in(conn, user), ~p"/journal")

      assert has_element?(view, "#product-tour")
      assert has_element?(view, "#product-tour", "Setting up #{poet.name}'s room")
      for slide <- ProductTour.slides(), do: assert(has_element?(view, "#tour-slide-#{slide.id}"))
      # First on the page, the rest of the wait below it.
      [before_tour, _] = String.split(html, ~s(id="product-tour"), parts: 2)
      refute before_tour =~ ~s(id="setup-card")
      assert html =~ ~s(id="setup-card")
    end

    test "and while the first page is being written", %{conn: conn} do
      user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
      poet = poet_fixture(user)
      {:ok, _} = TravelingPoet.Usage.record(user.id, "first_entry_attempt")

      {:ok, _view, html} = live(signed_in(conn, user), ~p"/journal")

      assert html =~ ~s(id="product-tour")
      assert html =~ "#{poet.name} is writing your first page"
    end

    test "when the page lands the tour stays, with a way to the page", %{conn: conn} do
      user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
      poet = poet_fixture(user)
      {:ok, view, _html} = live(signed_in(conn, user), ~p"/journal")

      entry = publish(poet, "Setting out")
      send(view.pid, {:journal_published, entry.id})

      assert has_element?(view, "#product-tour-ready", "Your first page is here")
      assert render(view) =~ "Setting out"

      view |> element("#product-tour-ready button", "Read it") |> render_click()
      refute has_element?(view, "#product-tour")
      assert has_element?(view, "#poet-map")
    end
  end

  test "a reader with pages sees no tour, until they ask for it", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user)
    publish(poet, "Day one")

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/journal")
    refute has_element?(view, "#product-tour")

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/journal?tour=1")
    assert has_element?(view, "#product-tour")
    refute has_element?(view, "#product-tour-ready")

    view |> element("#product-tour button", "Close") |> render_click()
    refute has_element?(view, "#product-tour")
  end

  test "Settings links to the tour", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true})
    poet_fixture(user)

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/settings")
    assert has_element?(view, ~s(#take-the-tour[href="/journal?tour=1"]))
  end
end
