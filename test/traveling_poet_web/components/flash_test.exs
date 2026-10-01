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

  test "the reconnect notices stay until the connection is back" do
    html = render_component(&Layouts.flash_group/1, flash: %{})

    for id <- ~w(client-error server-error) do
      [tag] = Regex.run(~r/<div[^>]*id="#{id}"[^>]*>/, html)
      refute tag =~ "AutoDismiss", "#{id} would close itself"
    end
  end
end
