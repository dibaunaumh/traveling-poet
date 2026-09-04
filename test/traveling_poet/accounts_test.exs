defmodule TravelingPoet.AccountsTest do
  use TravelingPoet.DataCase, async: false

  alias TravelingPoet.{Accounts, Credits}

  @profile %{"sub" => "g-123", "email" => "new@example.com", "name" => "New"}

  test "first OAuth sign-in grants welcome credits; later sign-ins don't" do
    {:ok, user} = Accounts.find_or_create_from_oauth(:google, @profile)
    assert Credits.balance(user) == 10_000

    {:ok, again} = Accounts.find_or_create_from_oauth(:google, @profile)
    assert again.id == user.id
    assert Credits.balance(Accounts.get_user!(user.id)) == 10_000
    assert length(Credits.list_transactions(user)) == 1
  end

  describe "touch_last_seen/2" do
    test "stamps a never-seen user and skips the write inside the debounce window" do
      {:ok, user} = Accounts.find_or_create_from_oauth(:google, @profile)
      assert user.last_seen_at == nil

      t0 = ~U[2026-09-03 12:00:00Z]
      seen = Accounts.touch_last_seen(user, t0)
      assert seen.last_seen_at == t0
      assert Accounts.get_user!(user.id).last_seen_at == t0

      # Two minutes later: within the window, nothing written.
      seen = Accounts.touch_last_seen(seen, DateTime.add(t0, 120, :second))
      assert seen.last_seen_at == t0
      assert Accounts.get_user!(user.id).last_seen_at == t0

      # Ten minutes later: stamped again.
      t1 = DateTime.add(t0, 600, :second)
      seen = Accounts.touch_last_seen(seen, t1)
      assert seen.last_seen_at == t1
      assert Accounts.get_user!(user.id).last_seen_at == t1
    end

    test "is nil-safe" do
      assert Accounts.touch_last_seen(nil) == nil
    end
  end
end
