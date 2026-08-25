defmodule TravelingPoet.TelegramPairingTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Telegram.Pairing

  setup do
    prev_token = Application.get_env(:traveling_poet, :telegram_bot_token)
    prev_username = Application.get_env(:traveling_poet, :telegram_bot_username)
    Application.put_env(:traveling_poet, :telegram_bot_token, "test-token")
    Application.put_env(:traveling_poet, :telegram_bot_username, "tpoet_test_bot")

    on_exit(fn ->
      Application.put_env(:traveling_poet, :telegram_bot_token, prev_token)
      Application.put_env(:traveling_poet, :telegram_bot_username, prev_username)
    end)

    %{user: user_fixture()}
  end

  test "mint + complete pairing round-trip", %{user: user} do
    {:ok, link} = Pairing.mint_pair_link(user)
    assert link =~ "https://t.me/tpoet_test_bot?start="

    token = link |> String.split("start=") |> List.last()

    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")

    assert {:ok, paired} = Pairing.complete_pairing(token, 123_456, "udi_test")
    assert paired.telegram_chat_id == 123_456
    assert paired.telegram_username == "udi_test"
    assert paired.telegram_pair_token == nil

    assert_receive {:telegram_paired, "udi_test"}

    # token is single-use
    assert {:error, :invalid_token} = Pairing.complete_pairing(token, 999, "other")
  end

  test "expired tokens are rejected", %{user: user} do
    {:ok, _link} = Pairing.mint_pair_link(user)
    user = TravelingPoet.Accounts.get_user!(user.id)

    {:ok, _} =
      TravelingPoet.Accounts.update_user(user, %{
        telegram_pair_token_expires_at:
          DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)
      })

    assert {:error, :invalid_token} =
             Pairing.complete_pairing(user.telegram_pair_token, 123, "x")
  end
end
