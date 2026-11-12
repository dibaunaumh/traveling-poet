defmodule TravelingPoet.GatewaySocketSupervisorTest do
  use TravelingPoet.DataCase, async: false

  import ExUnit.CaptureLog
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, AgentSession, GatewaySocketSupervisor}

  setup do
    Application.put_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClientRecorder)
    Application.put_env(:traveling_poet, :sprites_client_listener, self())

    on_exit(fn ->
      Application.delete_env(:traveling_poet, :sprites_client)
      Application.delete_env(:traveling_poet, :sprites_client_listener)
    end)

    :ok
  end

  # A sprite whose gateway is not up yet: nothing listens on the port.
  defp cold_user do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, user} =
      Accounts.update_user(agent_user_fixture(), %{
        sprite_name: "sprite-cold",
        sprite_url: "http://127.0.0.1:1",
        gateway_token: "t",
        device_public_key: pub,
        device_private_key: priv
      })

    user
  end

  defp tries(log), do: length(Regex.scan(~r/Failed to start GatewaySocket/, log))

  test "a gateway still booting is retried for the whole time budget, not six tries" do
    user = cold_user()

    log =
      capture_log(fn ->
        assert {:error, _} =
                 GatewaySocketSupervisor.ensure_connected(user,
                   attempts: 2,
                   within_ms: 400,
                   retry_delay_ms: 20
                 )
      end)

    assert tries(log) > 2
    # woken once, after the first failure
    assert_received {:sprites_exec, "sprite-cold", "true"}
  end

  test "a user with no device keys is not retried" do
    user = agent_user_fixture()
    started = System.monotonic_time(:millisecond)

    assert {:error, :no_device_keys} =
             GatewaySocketSupervisor.ensure_connected(user, attempts: 3, within_ms: 5_000)

    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "a headless turn holds the sprite awake before it connects" do
    {:ok, user} = Accounts.update_user(agent_user_fixture(), %{sprite_name: "sprite-cold"})

    assert {:error, _} = AgentSession.run(user, "/travel-and-journal")

    # the hold was put even though the gateway never answered
    assert_received {:sprites_exec, "sprite-cold", cmd}
    assert cmd =~ "-X PUT http://sprite/v1/tasks"
  end
end
