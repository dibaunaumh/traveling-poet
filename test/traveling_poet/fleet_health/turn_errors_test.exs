defmodule TravelingPoet.FleetHealth.TurnErrorsTest do
  @moduledoc """
  A failed poet turn pages the admins once, with what the poet was doing
  and the provider's own error, and is counted every time. Udi's poet
  (2026-10-16) failed chat for an evening with nothing but "Agent error" in
  the reader's chat; the 404 behind it was in the sprite's gateway log.
  """
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.FleetHealth.TurnErrors
  alias TravelingPoet.Usage

  setup do
    user = agent_user_fixture(%{sprite_name: "sandbox-test-9"})
    poet = poet_fixture(user, %{name: "Marta"})
    test = self()

    opts = [
      notify: fn text -> send(test, {:paged, text}) && :ok end,
      raw: fn u ->
        send(test, {:raw_for, u.id}) && "404 No endpoints found that support image input"
      end
    ]

    %{user: user, poet: poet, opts: opts}
  end

  test "the first failed turn pages with the channel and the provider error", %{
    user: user,
    opts: opts
  } do
    {:ok, _} = Usage.record(user.id, "daily_run_attempt")

    assert {:ok, :paged} =
             TurnErrors.report(user.id, "The AI service couldn't accept this request.", opts)

    assert_received {:raw_for, _}
    assert_received {:paged, text}
    assert text =~ "Marta"
    assert text =~ user.email
    assert text =~ "during daily run"
    assert text =~ "Gateway said: The AI service couldn't accept this request."
    assert text =~ "Provider error: 404 No endpoints found that support image input"
  end

  test "a turn with no attempt behind it is a chat, and no raw error is no line", %{
    user: user,
    opts: opts
  } do
    opts = Keyword.put(opts, :raw, fn _ -> nil end)
    assert {:ok, :paged} = TurnErrors.report(user.id, "Chat error", opts)
    assert_received {:paged, text}
    assert text =~ "during chat"
    refute text =~ "Provider error"
  end

  test "three error events of one failed turn, reported at once, page once", %{
    user: user,
    opts: opts
  } do
    Ecto.Adapters.SQL.Sandbox.mode(TravelingPoet.Repo, {:shared, self()})

    messages = [
      "OpenClaw couldn't finish this reply.",
      "Chat error",
      "Chat error"
    ]

    results =
      messages
      |> Enum.map(fn m -> Task.async(fn -> TurnErrors.report(user.id, m, opts) end) end)
      |> Task.await_many()

    assert Enum.sort(results) == [{:ok, :paged}, {:ok, :quiet}, {:ok, :quiet}]
    assert_received {:paged, _}
    refute_received {:paged, _}
    assert Usage.today_count(user.id, "turn_error") == 3
    assert Usage.today_count(user.id, "turn_error_alert") == 1
  end

  test "repeats within the quiet window are counted, not paged", %{user: user, opts: opts} do
    assert {:ok, :paged} = TurnErrors.report(user.id, "first", opts)
    assert_received {:paged, _}
    assert_received {:raw_for, _}

    assert {:ok, :quiet} = TurnErrors.report(user.id, "second", opts)
    refute_received {:paged, _}
    refute_received {:raw_for, _}

    later = DateTime.add(DateTime.utc_now(), 5, :hour)
    assert {:ok, :paged} = TurnErrors.report(user.id, "third", Keyword.put(opts, :now, later))
    assert_received {:paged, _}

    kinds =
      TravelingPoet.Repo.all(
        from e in TravelingPoet.Usage.UsageEvent,
          where: e.user_id == ^user.id and e.kind in ["turn_error", "turn_error_alert"],
          select: e.kind
      )

    assert Enum.count(kinds, &(&1 == "turn_error")) == 3
    assert Enum.count(kinds, &(&1 == "turn_error_alert")) == 2
  end

  test "nobody to page still counts the failure", %{user: user, opts: opts} do
    opts = Keyword.put(opts, :notify, fn _ -> {:error, :no_recipients} end)
    assert {:error, :no_recipients} = TurnErrors.report(user.id, "x", opts)

    assert TravelingPoet.Repo.exists?(
             from e in TravelingPoet.Usage.UsageEvent, where: e.kind == "turn_error"
           )
  end

  test "the provider error is the gateway log's last rawErrorPreview, nothing when the sprite is quiet",
       %{user: user} do
    Application.put_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClientRecorder)
    Application.put_env(:traveling_poet, :sprites_client_listener, self())

    on_exit(fn ->
      Application.delete_env(:traveling_poet, :sprites_client)
      Application.delete_env(:traveling_poet, :sprites_client_listener)
    end)

    assert TurnErrors.gateway_error(user) == nil
    assert_received {:sprites_exec, "sandbox-test-9", cmd}
    assert cmd =~ "rawErrorPreview"
    assert cmd =~ "/tmp/openclaw/openclaw-"
  end
end
