defmodule TravelingPoetWeb.TelegramPairingLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  setup do
    prev_token = Application.get_env(:traveling_poet, :telegram_bot_token)
    prev_username = Application.get_env(:traveling_poet, :telegram_bot_username)
    Application.put_env(:traveling_poet, :telegram_bot_token, "test-token")
    Application.put_env(:traveling_poet, :telegram_bot_username, "tpoet_test_bot")

    on_exit(fn ->
      Application.put_env(:traveling_poet, :telegram_bot_token, prev_token)
      Application.put_env(:traveling_poet, :telegram_bot_username, prev_username)
    end)

    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user, %{name: "Solveig"})

    %{
      conn: Plug.Test.init_test_session(build_conn(), %{user_id: user.id}),
      user: user,
      poet: poet
    }
  end

  # What the poller writes when the user presses Start in Telegram.
  defp pair(user) do
    {:ok, _} =
      TravelingPoet.Accounts.update_user(user, %{telegram_chat_id: 123, telegram_username: "udi"})
  end

  test "the journal tip pairs right there and hears the poller", %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, ~p"/journal")
    assert html =~ ~s(id="telegram-tip")
    assert html =~ "Get the first entry on Telegram."

    html = view |> element("#telegram-tip button", "Pair Telegram") |> render_click()
    assert html =~ "https://t.me/tpoet_test_bot?start="
    assert html =~ "Open Telegram and press Start"

    pair(user)
    send(view.pid, {:telegram_paired, "udi"})
    html = render(view)
    assert html =~ "Telegram is paired as @udi."
    assert html =~ "Solveig will write to you there"
    refute html =~ "Pair Telegram"
  end

  test "settings still mints and unpairs", %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, ~p"/settings")
    assert html =~ "Generate pairing link"

    html = view |> element("button", "Generate pairing link") |> render_click()
    assert html =~ "https://t.me/tpoet_test_bot?start="

    pair(user)
    send(view.pid, {:telegram_paired, "udi"})
    html = render(view)
    assert html =~ "Paired as @udi"

    html = view |> element("button", "Unpair") |> render_click()
    assert html =~ "Generate pairing link"
  end

  test "without a bot the tip stays out of the way", %{conn: conn} do
    Application.put_env(:traveling_poet, :telegram_bot_token, nil)
    {:ok, _view, html} = live(conn, ~p"/journal")
    refute html =~ ~s(id="telegram-tip")
    assert html =~ ~s(id="waiting-tips")
  end
end
