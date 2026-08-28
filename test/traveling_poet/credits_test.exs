defmodule TravelingPoet.CreditsTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Credits}
  alias TravelingPoet.Credits.CreditTransaction

  defp reload(user), do: Accounts.get_user!(user.id)

  test "grants and debits keep balance_after and the cached balance in sync" do
    user = user_fixture()
    assert Credits.balance(user) == 0

    {:ok, tx} = Credits.grant_signup(user)
    assert tx.amount == 10_000
    assert tx.balance_after == 10_000
    assert Credits.balance(reload(user)) == 10_000

    poet = poet_fixture(user)
    {:ok, debit} = Credits.debit_daily_run(reload(user), poet, 42)
    assert debit.amount == -1000
    assert debit.balance_after == 9000
    assert Credits.balance(reload(user)) == 9000
  end

  test "a debit below zero is refused and leaves no row" do
    user = user_fixture(%{credits: 2})
    poet = poet_fixture(user, %{settings: %{"mode" => "scout"}})

    assert Credits.daily_run_cost(poet) == 5000
    refute Credits.can_run?(user, poet)
    assert {:error, :insufficient_credits} = Credits.debit_daily_run(user, poet, 1)
    assert Credits.balance(reload(user)) == 2000
    assert Repo.aggregate(CreditTransaction, :count) == 1
  end

  test "the same reference is applied at most once" do
    user = user_fixture()
    assert {:ok, %CreditTransaction{}} = Credits.purchase(user, "p10", "stripe:cs_1")
    assert {:ok, :duplicate} = Credits.purchase(user, "p10", "stripe:cs_1")
    assert Credits.balance(reload(user)) == 10_000
    assert {:error, :unknown_pack} = Credits.purchase(user, "nope", "stripe:cs_2")
  end

  test "signup grant is idempotent" do
    user = user_fixture()
    {:ok, _} = Credits.grant_signup(user)
    {:ok, :duplicate} = Credits.grant_signup(user)
    assert Credits.balance(reload(user)) == 10_000
  end

  test "refund restores a debit once" do
    user = user_fixture(%{credits: 3})
    poet = poet_fixture(user)
    {:ok, _} = Credits.debit_daily_run(user, poet, 7)
    assert Credits.balance(reload(user)) == 2000

    {:ok, %CreditTransaction{kind: "refund"}} = Credits.refund_daily_run(user, 7)
    assert Credits.balance(reload(user)) == 3000
    # replay: the refund reference is already taken
    assert {:ok, :duplicate} = Credits.refund_daily_run(user, 7)
    assert {:ok, :nothing_to_refund} = Credits.refund_daily_run(user, 999)
    assert Credits.balance(reload(user)) == 3000
  end

  test "quota_exempt users are free and never low" do
    user = user_fixture(%{quota_exempt: true})
    poet = poet_fixture(user)
    assert Credits.can_run?(user, poet)
    assert {:ok, :exempt} = Credits.debit_daily_run(user, poet, 1)
    assert Credits.runway_days(user, poet) == nil
    refute Credits.low?(user, poet)
    refute Credits.exhausted?(user, poet)
  end

  test "runway follows the mission rate" do
    user = user_fixture(%{credits: 10})
    wander = poet_fixture(user)
    assert Credits.runway_days(user, wander) == 10.0
    refute Credits.low?(user, wander)

    {:ok, scout} = TravelingPoet.Poets.update_poet(wander, %{settings: %{"mode" => "scout"}})
    assert Credits.runway_days(user, scout) == 2.0
    assert Credits.low?(user, scout)
    refute Credits.exhausted?(user, scout)
  end

  test "a debit that drops runway below the threshold alerts once per day" do
    user = user_fixture(%{credits: 3})
    poet = poet_fixture(user)
    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")
    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "credits:low")

    {:ok, _} = Credits.debit_daily_run(user, poet, 1)
    assert_receive {:credits_updated, 2000}
    assert_receive {:credits_low, user_id, 2000}
    assert user_id == user.id
    # global topic gets the same message
    assert_receive {:credits_low, ^user_id, 2000}

    {:ok, _} = Credits.debit_daily_run(reload(user), poet, 2)
    assert_receive {:credits_updated, 1000}
    refute_receive {:credits_low, _, _}, 50
  end

  test "format renders whole and fractional credits" do
    assert Credits.format(10_000) == "10"
    assert Credits.format(9_500) == "9.5"
    assert Credits.format(0) == "0"
  end
end
