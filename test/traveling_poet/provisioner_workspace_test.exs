defmodule TravelingPoet.ProvisionerWorkspaceTest do
  # Rolling workspace and plugin changes onto a live poet (upgrade_workspace,
  # upgrade_fleet), against a fake sprite that records what it is asked, in
  # order. On 2026-10-19 the plugin was installed into a running gateway and
  # 16 of 36 poets timed out waiting for it to drain.
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Provisioner}

  defmodule FakeSprite do
    @moduledoc false
    # Every call goes to the test pid; `cat` of the plugin digest answers
    # what the test put in :fake_plugin_digest.
    def exec(name, cmd, _opts \\ []) do
      send(listener(), {:call, {:exec, name, cmd}})

      if cmd =~ ".tpoet-digest" and cmd =~ "cat ",
        do: {:ok, Application.get_env(:traveling_poet, :fake_plugin_digest, "") <> "\n"},
        else: {:ok, ""}
    end

    def stop_service(name, svc), do: call({:stop, name, svc})
    def start_service(name, svc), do: call({:start, name, svc})
    def get_service(name, svc), do: call({:get_service, name, svc})
    def create_service(name, svc, _cmd, _args \\ [], _opts \\ []), do: call({:create, name, svc})

    defp call(event) do
      send(listener(), {:call, event})
      {:ok, %{}}
    end

    defp listener, do: Application.fetch_env!(:traveling_poet, :sprites_client_listener)
  end

  setup do
    Application.put_env(:traveling_poet, :sprites_client, FakeSprite)
    Application.put_env(:traveling_poet, :sprites_client_listener, self())

    on_exit(fn ->
      Application.delete_env(:traveling_poet, :sprites_client)
      Application.delete_env(:traveling_poet, :sprites_client_listener)
      Application.delete_env(:traveling_poet, :fake_plugin_digest)
    end)

    user = agent_user_fixture()

    {:ok, user} =
      Accounts.update_user(user, %{gateway_token: "gw-token", sprite_name: "sprite-x"})

    _poet = poet_fixture(user)

    %{user: user}
  end

  defp calls do
    receive do
      {:call, event} -> [event | calls()]
    after
      0 -> []
    end
  end

  defp index(calls, fun), do: Enum.find_index(calls, fun)
  defp install?({:exec, _, cmd}), do: cmd =~ "plugins install"
  defp install?(_), do: false

  test "the gateway is stopped before the plugin is installed, and started after", %{
    user: user
  } do
    assert {:ok, "sprite-x"} = Provisioner.upgrade_workspace(user)

    calls = calls()
    stop = index(calls, &match?({:stop, "sprite-x", "openclaw-gateway"}, &1))
    install = index(calls, &install?/1)

    start =
      calls |> Enum.with_index() |> Enum.filter(&match?({{:start, _, _}, _}, &1)) |> List.last()

    assert stop && install && start
    assert stop < install
    assert install < elem(start, 1)

    # the digest of what was installed is left beside it
    assert Enum.any?(calls, &match?({:exec, _, "echo " <> _}, &1))
  end

  test "a plugin the sprite already runs is not installed again", %{user: user} do
    phoenix_url = Application.get_env(:traveling_poet, :phoenix_url, "http://localhost:4000")

    Application.put_env(
      :traveling_poet,
      :fake_plugin_digest,
      Provisioner.plugin_digest(phoenix_url, user.agent_api_token)
    )

    assert {:ok, _} = Provisioner.upgrade_workspace(user)

    calls = calls()
    refute Enum.any?(calls, &install?/1)
    # the workspace and the restart still happen
    assert Enum.any?(calls, &match?({:start, _, "openclaw-gateway"}, &1))
  end

  test "a different plugin, or none recorded, is installed" do
    assert Provisioner.plugin_digest("https://a", "1.x") !=
             Provisioner.plugin_digest("https://b", "1.x")

    Application.put_env(:traveling_poet, :fake_plugin_digest, "stale")
    assert {:ok, :written} = Provisioner.ensure_plugin("sprite-x", "https://a", "1.x")
    assert Enum.any?(calls(), &install?/1)
  end

  describe "upgrade_fleet" do
    test "skips a poet mid-run, verifies the rest, and says which is which", %{user: user} do
      other = agent_user_fixture()
      broken = agent_user_fixture()

      results =
        Provisioner.upgrade_fleet(
          users: [user, other, broken],
          stagger_ms: 0,
          busy?: &(&1 == other.id),
          workspace: fn u ->
            send(self(), {:workspace, u.id})
            {:ok, "sprite-#{u.id}"}
          end,
          verify: fn u -> if u.id == broken.id, do: {:error, :timeout}, else: :ok end
        )

      assert results == [
               {user.email, :ok},
               {other.email, :skipped_busy},
               {broken.email, {:error, :timeout}}
             ]

      user_id = user.id
      other_id = other.id
      assert_received {:workspace, ^user_id}
      refute_received {:workspace, ^other_id}
    end

    test "force upgrades a busy poet anyway", %{user: user} do
      assert [{_, :ok}] =
               Provisioner.upgrade_fleet(
                 users: [user],
                 stagger_ms: 0,
                 force: true,
                 busy?: fn _ -> true end,
                 workspace: fn _ -> {:ok, "s"} end,
                 verify: fn _ -> :ok end
               )
    end
  end
end
