defmodule TravelingPoet.DailyJourneySchedulerTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{DailyJourneyScheduler, Usage}

  test "a run needs both the daily cap and enough credits" do
    user = user_fixture(%{credits: 1})
    poet = poet_fixture(user)
    assert DailyJourneyScheduler.eligible(user, poet) == :ok

    {:ok, _} = TravelingPoet.Poets.update_poet(poet, %{settings: %{"mode" => "scout"}})
    scout = TravelingPoet.Poets.get_poet_by_user(user.id)
    assert DailyJourneyScheduler.eligible(user, scout) == {:skip, "out of credits"}

    {:ok, _} = Usage.record(user.id, "daily_run")
    assert DailyJourneyScheduler.eligible(user, poet) == {:skip, "over budget"}
  end

  test "exempt users are always eligible on credits" do
    user = user_fixture(%{quota_exempt: true})
    poet = poet_fixture(user)
    assert DailyJourneyScheduler.eligible(user, poet) == :ok
  end

  describe "a retry starts from a fresh conversation" do
    setup do
      Application.put_env(:traveling_poet, :fresh_start_on_retry, true)
      Application.put_env(:traveling_poet, :gateway_boot_ms, 0)
      Application.put_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClientRecorder)
      Application.put_env(:traveling_poet, :sprites_client_listener, self())

      on_exit(fn ->
        Application.put_env(:traveling_poet, :fresh_start_on_retry, false)
        Application.delete_env(:traveling_poet, :gateway_boot_ms)
        Application.delete_env(:traveling_poet, :sprites_client)
        Application.delete_env(:traveling_poet, :sprites_client_listener)
      end)

      %{user: user_fixture(%{sprite_provisioned: true, sprite_name: "sprite-ezra"})}
    end

    test "the day's first attempt keeps the conversation", %{user: user} do
      assert DailyJourneyScheduler.before_attempt(user, false) == :first
      refute_received {:sprites_service, _, _, _}
    end

    # Samuel's poet, 2026-09-30: the first run overflowed its context and both
    # retries continued the same overflowed session.
    test "a retry sets the old conversation aside first", %{user: user} do
      assert DailyJourneyScheduler.before_attempt(user, true) == :ok

      assert_received {:sprites_service, "sprite-ezra", :stop, "openclaw-gateway"}
      assert_received {:sprites_exec, "sprite-ezra", cmd}
      assert cmd =~ "sessions-reset-"
      assert_received {:sprites_service, "sprite-ezra", :start, "openclaw-gateway"}
    end
  end
end
