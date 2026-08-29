defmodule TravelingPoet.MessagingTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Messaging

  setup do
    prev = %{
      telegram_token: Application.get_env(:traveling_poet, :telegram_bot_token),
      telegram_username: Application.get_env(:traveling_poet, :telegram_bot_username),
      wa_token: Application.get_env(:traveling_poet, :whatsapp_access_token),
      wa_phone: Application.get_env(:traveling_poet, :whatsapp_phone_number_id),
      wa_number: Application.get_env(:traveling_poet, :whatsapp_business_number)
    }

    Application.put_env(:traveling_poet, :telegram_bot_token, "test-token")
    Application.put_env(:traveling_poet, :telegram_bot_username, "tpoet_test_bot")
    Application.put_env(:traveling_poet, :whatsapp_access_token, "wa-test-token")
    Application.put_env(:traveling_poet, :whatsapp_phone_number_id, "123456")
    Application.put_env(:traveling_poet, :whatsapp_business_number, "+1 555 0123456")

    on_exit(fn ->
      Application.put_env(:traveling_poet, :telegram_bot_token, prev.telegram_token)
      Application.put_env(:traveling_poet, :telegram_bot_username, prev.telegram_username)
      Application.put_env(:traveling_poet, :whatsapp_access_token, prev.wa_token)
      Application.put_env(:traveling_poet, :whatsapp_phone_number_id, prev.wa_phone)
      Application.put_env(:traveling_poet, :whatsapp_business_number, prev.wa_number)
    end)

    %{user: user_fixture()}
  end

  # Both deep links carry the token in a query param — `?start=<token>` for
  # Telegram, `?text=PAIR+<token>` for WhatsApp.
  defp token_from(link) do
    link
    |> String.split(~r/[?&](?:start|text)=/)
    |> List.last()
    |> URI.decode_www_form()
    |> String.replace(~r/^PAIR\s+/i, "")
  end

  test "telegram mint + complete pairing round-trip", %{user: user} do
    {:ok, link} = Messaging.mint_pair_link(user, "telegram")
    assert link =~ "https://t.me/tpoet_test_bot?start="

    token = token_from(link)
    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")

    assert {:ok, paired_user, channel} =
             Messaging.complete_pairing("telegram", token, 123_456, "udi_test")

    assert paired_user.id == user.id
    assert channel.external_id == "123456"
    assert channel.username == "udi_test"
    assert channel.pair_token == nil
    assert Messaging.paired?(user, "telegram")

    assert_receive {:messaging_paired, "telegram", "udi_test"}

    # token is single-use
    assert {:error, :invalid_token} =
             Messaging.complete_pairing("telegram", token, 999, "other")
  end

  test "whatsapp pair link prefills the PAIR message", %{user: user} do
    {:ok, link} = Messaging.mint_pair_link(user, "whatsapp")
    # non-digits are stripped from the business number
    assert link =~ "https://wa.me/15550123456?text=PAIR"

    assert {:ok, _user, channel} =
             Messaging.complete_pairing(
               "whatsapp",
               token_from(link),
               "15559998888",
               "Beta Tester"
             )

    assert channel.provider == "whatsapp"
    assert channel.external_id == "15559998888"
    assert Messaging.paired?(user, "whatsapp")
    # pairing one provider leaves the other alone
    refute Messaging.paired?(user, "telegram")
  end

  test "a user can be paired on both providers at once", %{user: user} do
    {:ok, tg} = Messaging.mint_pair_link(user, "telegram")
    {:ok, _user, _} = Messaging.complete_pairing("telegram", token_from(tg), 1001, "tg")

    {:ok, wa} = Messaging.mint_pair_link(user, "whatsapp")
    {:ok, _user, _} = Messaging.complete_pairing("whatsapp", token_from(wa), "15551110000", "wa")

    assert Messaging.paired_channels(user.id) |> Enum.map(& &1.provider) |> Enum.sort() ==
             ["telegram", "whatsapp"]

    assert Messaging.any_paired?(user)
  end

  test "expired tokens are rejected", %{user: user} do
    {:ok, link} = Messaging.mint_pair_link(user, "telegram")
    channel = Messaging.get_channel(user.id, "telegram")

    {:ok, _} =
      channel
      |> TravelingPoet.Messaging.Channel.changeset(%{
        pair_token_expires_at: DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)
      })
      |> TravelingPoet.Repo.update()

    assert {:error, :invalid_token} =
             Messaging.complete_pairing("telegram", token_from(link), 123, "x")
  end

  test "re-pairing a conversation moves it off the previous owner", %{user: user} do
    other = user_fixture()

    {:ok, link} = Messaging.mint_pair_link(other, "whatsapp")
    {:ok, _, _} = Messaging.complete_pairing("whatsapp", token_from(link), "15557654321", "old")
    assert Messaging.paired?(other, "whatsapp")

    {:ok, link2} = Messaging.mint_pair_link(user, "whatsapp")
    {:ok, _, _} = Messaging.complete_pairing("whatsapp", token_from(link2), "15557654321", "new")

    assert Messaging.paired?(user, "whatsapp")
    refute Messaging.paired?(other, "whatsapp")
  end

  test "unpair clears the conversation but keeps the row", %{user: user} do
    {:ok, link} = Messaging.mint_pair_link(user, "telegram")
    {:ok, _, _} = Messaging.complete_pairing("telegram", token_from(link), 555, "x")

    assert {:ok, _} = Messaging.unpair(user, "telegram")
    refute Messaging.paired?(user, "telegram")
    assert Messaging.paired_channels(user.id) == []
  end

  test "configured_providers reflects credentials" do
    assert Messaging.configured_providers() == ["telegram", "whatsapp"]

    Application.put_env(:traveling_poet, :whatsapp_access_token, nil)
    assert Messaging.configured_providers() == ["telegram"]
  end
end
