defmodule TravelingPoet.OpenRouterTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.OpenRouter

  test "an unset key is an error, not a healthy balance" do
    # runtime.exs deliberately leaves the key nil in test
    assert OpenRouter.key_status() == {:error, :not_configured}
  end

  # The /key answer of 2026-10-17: a lifetime `usage` above the monthly
  # `limit`, with OpenRouter's own `limit_remaining` saying $46 is left.
  @key %{
    "limit" => 100,
    "limit_reset" => "monthly",
    "limit_remaining" => 46.721365954,
    "usage" => 136.591951818,
    "usage_monthly" => 53.278634046
  }

  test "the key's monthly headroom is what OpenRouter says is left, not limit minus lifetime usage" do
    s = OpenRouter.summarize(@key)
    assert s.remaining == 46.7214
    assert_in_delta s.usage, 53.2786, 0.001
    assert s.limit == 100.0
    assert s.scope == :key
    refute s.exhausted?
    refute s.low?
  end

  test "the account balance binds when it is lower than the key's allowance" do
    s = OpenRouter.summarize(@key, %{"total_credits" => 205, "total_usage" => 204.5})
    assert s.scope == :account
    assert s.remaining == 0.5
    assert s.limit == 205.0
    assert s.account_remaining == 0.5
    assert s.low?
    refute s.exhausted?

    s = OpenRouter.summarize(@key, %{"total_credits" => 205, "total_usage" => 146.6})
    assert s.scope == :key
    assert s.remaining == 46.7214
    assert s.account_remaining == 58.4
  end

  test "a key with no cap and no readable balance is unknown, not exhausted" do
    s = OpenRouter.summarize(%{"usage" => 500.0, "limit" => nil})
    assert s.remaining == nil
    refute s.exhausted?
    refute s.low?
  end

  test "an exhausted monthly allowance still reads as exhausted" do
    s =
      OpenRouter.summarize(%{
        "limit" => 100,
        "limit_reset" => "monthly",
        "limit_remaining" => 0,
        "usage_monthly" => 100.0
      })

    assert s.exhausted?
  end
end
