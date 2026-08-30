defmodule TravelingPoet.OpenRouterTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.OpenRouter

  test "an unset key is an error, not a healthy balance" do
    # runtime.exs deliberately leaves the key nil in test
    assert OpenRouter.key_status() == {:error, :not_configured}
  end
end
