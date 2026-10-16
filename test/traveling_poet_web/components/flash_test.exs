defmodule TravelingPoetWeb.FlashTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias TravelingPoetWeb.{CoreComponents, Layouts}

  # Udi, 2026-10-01: in the iPhone app the welcome banner sat over the
  # Dynamic Island and stayed until closed by hand.
  test "a message closes itself: sooner for news, later for errors" do
    info = render_component(&CoreComponents.flash/1, kind: :info, flash: %{"info" => "Welcome!"})
    assert info =~ ~s(phx-hook="AutoDismiss")
    assert info =~ ~s(data-autohide-ms="5000")

    error = render_component(&CoreComponents.flash/1, kind: :error, flash: %{"error" => "Oops"})
    assert error =~ ~s(data-autohide-ms="9000")
  end

  # Udi, card-99: the stock red "We can't find the internet" scared readers
  # when it was the server restarting on a deploy. One quiet notice now,
  # shown late by reconnect_notice.js, and never closing itself.
  test "a dropped connection is one quiet notice that waits for the connection to be back" do
    html = render_component(&Layouts.flash_group/1, flash: %{})

    [tag] = Regex.run(~r/<div[^>]*id="reconnecting"[^>]*>/, html)
    assert tag =~ ~s(hidden)
    assert tag =~ ~s(role="status")
    assert tag =~ "tpoet:disconnected"
    assert tag =~ "tpoet:connected"
    refute tag =~ "AutoDismiss"
    refute tag =~ "alert"

    assert html =~ "Reconnecting…"
    assert html =~ "Nothing is lost"
    refute html =~ "find the internet"
    refute html =~ "Something went wrong"
    refute html =~ ~s(id="client-error")
  end
end
