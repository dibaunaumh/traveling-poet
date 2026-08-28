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
end
