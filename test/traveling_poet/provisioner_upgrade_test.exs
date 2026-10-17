defmodule TravelingPoet.ProvisionerUpgradeTest do
  # The OpenClaw release upgrade of a live sprite, driven against a fake
  # sprite: what npm is asked, in which order the gateway stops and starts,
  # and that a poet is never left on a release the app cannot talk to.
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Provisioner, Usage}

  defmodule FakeSprites do
    @moduledoc false
    # One sprite, answered from an Agent: `installed` is what
    # `openclaw --version` says, an `npm install` started here lands when the
    # poll after it says "finished" (unless the release is in `fail`).

    def exec(name, cmd, _opts \\ []) do
      try do
        Agent.get_and_update(agent(), fn st -> answer(st, name, cmd) end)
      catch
        :exit, _ -> {:ok, ""}
      end
    end

    def stop_service(name, svc), do: note({:stop, name, svc})
    def start_service(name, svc), do: note({:start, name, svc})

    defp answer(st, name, cmd) do
      st = %{st | calls: st.calls ++ [{:exec, name, cmd}]}

      cond do
        cmd =~ "npm --version" ->
          {{:ok, st.npm <> "\n"}, st}

        cmd =~ "npm install -g openclaw@" ->
          [_, version] = Regex.run(~r/openclaw@(\S+)/, cmd)
          {{:ok, "started\n"}, %{st | installing: version, polls: 0}}

        cmd =~ "pgrep" and st.polls < 1 ->
          {{:ok, "running\n"}, %{st | polls: st.polls + 1}}

        cmd =~ "pgrep" ->
          landed = if st.installing in st.fail, do: st.installed, else: st.installing
          {{:ok, "finished\n"}, %{st | installed: landed, installing: nil}}

        cmd =~ "openclaw --version" ->
          {{:ok, if(st.installed, do: "OpenClaw #{st.installed} (383c124)\n", else: "")}, st}

        cmd =~ "doctor --fix" ->
          {{:ok, Map.get(st, :doctor, "Doctor complete.\n")}, st}

        cmd =~ "tail -c" ->
          {{:ok, "npm ERR! code E404\n"}, st}

        true ->
          {{:ok, ""}, st}
      end
    end

    defp note(event) do
      try do
        Agent.update(agent(), fn st -> %{st | calls: st.calls ++ [event]} end)
      catch
        :exit, _ -> :ok
      end

      {:ok, ""}
    end

    defp agent, do: Application.get_env(:traveling_poet, :fake_sprites)
  end

  setup do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{installed: "2026.4.9", installing: nil, polls: 0, fail: [], npm: "12.0.2", calls: []}
      end)

    Application.put_env(:traveling_poet, :sprites_client, FakeSprites)
    Application.put_env(:traveling_poet, :fake_sprites, agent)

    on_exit(fn ->
      Application.delete_env(:traveling_poet, :sprites_client)
      Application.delete_env(:traveling_poet, :fake_sprites)
    end)

    user = agent_user_fixture(%{sprite_name: "sandbox-test-7", openclaw_version: "2026.4.9"})
    %{user: user, agent: agent}
  end

  defp calls(agent), do: Agent.get(agent, & &1.calls)

  defp installs(agent) do
    for {:exec, _, cmd} <- calls(agent), cmd =~ "npm install -g openclaw@" do
      [_, v] = Regex.run(~r/openclaw@(\S+)/, cmd)
      v
    end
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        version: "2026.10.4",
        bridge: false,
        install_poll_ms: 1,
        workspace: fn u -> send(self(), {:workspace, u.id}) && {:ok, :rewritten} end,
        verify: fn _ -> :ok end
      ],
      extra
    )
  end

  test "provisioning runs doctor right after the config, before the plugin install" do
    steps = Provisioner.steps()

    assert Enum.find_index(steps, &(&1 == :write_config)) + 1 ==
             Enum.find_index(steps, &(&1 == :prepare_state))

    assert Enum.find_index(steps, &(&1 == :prepare_state)) <
             Enum.find_index(steps, &(&1 == :write_tpoet_plugin))
  end

  test "a plugin install that met a busy state store is a retry, not a failure" do
    busy =
      "Config health-state write failed: OpenClaw state at /home/sprite/.openclaw/state/openclaw.sqlite is undergoing offline maintenance; retry when it finishes.\nWARNING - Installing plugin from local path\nConfig invalid; run `openclaw doctor --fix` before installing plugins.\n" <>
        <<3, 1>>

    assert {:error, {:plugin_install_busy, _}} = Provisioner.plugin_installed(busy)

    assert {:error, {:plugin_install_failed, _}} =
             Provisioner.plugin_installed("Install cancelled; rerun with --force\n" <> <<3, 1>>)

    assert :ok = Provisioner.plugin_installed("Installed plugin tpoet-plugin\n" <> <<3, 0>>)
  end

  test "a first install holds the sprite awake while npm runs detached", %{agent: agent} do
    Agent.update(agent, &%{&1 | installed: nil})

    assert {:ok, _} =
             Provisioner.install_openclaw("sandbox-test-7", "2026.10.4", install_poll_ms: 1)

    calls = calls(agent)
    hold_at = Enum.find_index(calls, &match?({:exec, _, "curl" <> _}, &1))
    install_at = Enum.find_index(calls, &match?({:exec, _, "rm -f" <> _}, &1))

    assert hold_at, "no sprite hold was put"
    assert hold_at < install_at
    assert {:exec, _, cmd} = Enum.at(calls, hold_at)
    assert cmd =~ "PUT http://sprite/v1/tasks"
    assert cmd =~ "tpoet-install-"
    assert Agent.get(agent, & &1.installed) == "2026.10.4"
  end

  test "moves a poet to the release, gateway stopped first, and records it", %{
    user: user,
    agent: agent
  } do
    assert {:ok, "2026.10.4"} = Provisioner.upgrade_openclaw(user, opts())

    assert Accounts.get_user!(user.id).openclaw_version == "2026.10.4"
    assert installs(agent) == ["2026.10.4"]
    assert_received {:workspace, _}

    calls = calls(agent)
    stop_at = Enum.find_index(calls, &match?({:stop, "sandbox-test-7", "openclaw-gateway"}, &1))
    install_at = Enum.find_index(calls, &match?({:exec, _, "rm -f" <> _}, &1))

    doctor_at =
      Enum.find_index(calls, fn c ->
        match?({:exec, _, cmd} when is_binary(cmd), c) and elem(c, 2) =~ "doctor --fix"
      end)

    assert stop_at < install_at and install_at < doctor_at

    # npm 12 refuses lifecycle scripts unless named; OpenClaw's postinstall wires its plugins
    assert Enum.any?(calls, fn
             {:exec, _, cmd} -> cmd =~ "openclaw@2026.10.4 --allow-scripts=openclaw"
             _ -> false
           end)
  end

  test "an npm older than 11.16 gets no --allow-scripts flag", %{user: user, agent: agent} do
    Agent.update(agent, &%{&1 | npm: "10.9.2"})
    assert {:ok, "2026.10.4"} = Provisioner.upgrade_openclaw(user, opts())

    assert Enum.any?(calls(agent), fn
             {:exec, _, cmd} -> cmd =~ "openclaw@2026.10.4 --no-progress"
             _ -> false
           end)

    refute Enum.any?(calls(agent), fn
             {:exec, _, cmd} -> cmd =~ "allow-scripts"
             _ -> false
           end)
  end

  test "a release from before July 2026 goes through the bridge release first", %{
    user: user,
    agent: agent
  } do
    assert {:ok, "2026.10.4"} = Provisioner.upgrade_openclaw(user, opts(bridge: :auto))
    assert installs(agent) == ["2026.9.5", "2026.10.4"]

    doctors =
      Enum.count(calls(agent), fn
        {:exec, _, cmd} -> cmd =~ "doctor --fix"
        _ -> false
      end)

    assert doctors == 2
  end

  test "no bridge when the sprite is already past it", %{user: user, agent: agent} do
    Agent.update(agent, &%{&1 | installed: "2026.9.9"})
    assert {:ok, "2026.10.4"} = Provisioner.upgrade_openclaw(user, opts(bridge: :auto))
    assert installs(agent) == ["2026.10.4"]
  end

  # Once doctor has migrated the state at the new release there is no way
  # back (OpenClaw's own guide; a 2026.4.9 gateway restarted on a migrated
  # store answered "pairing required" to everything). The sprite stays on the
  # release, unrecorded, and the next pass redoes only the last phase.
  test "a failed handshake after the install leaves the release in place, unrecorded", %{
    user: user,
    agent: agent
  } do
    verify = fn _ ->
      if Process.get(:verified) do
        :ok
      else
        Process.put(:verified, true)
        {:error, :handshake_timeout}
      end
    end

    assert {:error, {:handshake_timeout, installed: "2026.10.4"}} =
             Provisioner.upgrade_openclaw(user, opts(verify: verify))

    assert installs(agent) == ["2026.10.4"]
    assert Accounts.get_user!(user.id).openclaw_version == "2026.4.9"

    # the next pass: no install, only config, doctor, workspace and handshake
    assert {:ok, "2026.10.4"} = Provisioner.upgrade_openclaw(user, opts(verify: verify))
    assert installs(agent) == ["2026.10.4"]
    assert Accounts.get_user!(user.id).openclaw_version == "2026.10.4"
  end

  test "an install that never lands fails with npm's last words, the old release restarts", %{
    user: user,
    agent: agent
  } do
    Agent.update(agent, &%{&1 | fail: ["2026.10.4"]})

    assert {:error, {{:install_failed, "2026.10.4", "2026.4.9", log}, rolled_back: :ok}} =
             Provisioner.upgrade_openclaw(user, opts())

    assert log =~ "E404"
    # npm left 2026.4.9 in place, so nothing is reinstalled; the gateway just restarts on it
    assert installs(agent) == ["2026.10.4"]
    assert Accounts.get_user!(user.id).openclaw_version == "2026.4.9"
    assert_received {:workspace, _}
  end

  test "a bridge whose target install fails restarts on the bridge, never before it", %{
    user: user,
    agent: agent
  } do
    Agent.update(agent, &%{&1 | fail: ["2026.10.4"]})

    assert {:error, {{:install_failed, "2026.10.4", "2026.9.5", _}, rolled_back: :ok}} =
             Provisioner.upgrade_openclaw(user, opts(bridge: :auto))

    assert installs(agent) == ["2026.9.5", "2026.10.4"]
    assert Accounts.get_user!(user.id).openclaw_version == "2026.9.5"
  end

  test "a poet mid-run is skipped, nothing touched", %{user: user, agent: agent} do
    {:ok, _} = Usage.record(user.id, "daily_run_attempt")
    assert {:skipped, :busy} = Provisioner.upgrade_openclaw(user, opts())
    assert installs(agent) == []
    refute Enum.any?(calls(agent), &match?({:stop, _, _}, &1))
  end

  test "a sprite on the release and recorded as such is left alone", %{user: user, agent: agent} do
    Agent.update(agent, &%{&1 | installed: "2026.10.4"})
    {:ok, user} = Accounts.update_user(user, %{openclaw_version: "2026.10.4"})
    assert {:ok, :already_current} = Provisioner.upgrade_openclaw(user, opts())
    assert installs(agent) == []
    refute_received {:workspace, _}
  end

  test "a sprite on the release but unrecorded gets the last phase only", %{
    user: user,
    agent: agent
  } do
    Agent.update(agent, &%{&1 | installed: "2026.10.4"})
    assert {:ok, "2026.10.4"} = Provisioner.upgrade_openclaw(user, opts())
    assert installs(agent) == []
    assert_received {:workspace, _}
    assert Accounts.get_user!(user.id).openclaw_version == "2026.10.4"
  end

  # User 7, 2026-10-16: doctor exited 0 after refusing the session migration
  # (a retired memory-core file blocked it), the gateway then died on every
  # start, and the upgrade reported a handshake timeout. The refusal is the
  # reason, and the one thing an operator can act on.
  test "a refused doctor migration is the reported reason, not the handshake timeout", %{
    user: user,
    agent: agent
  } do
    refusal = """
    Doctor stopped because a state migration refused to continue. Resolve the reported migration failure before retrying. Later repairs were not run.
    Failing check plugin-doctor-state (step-refused): Memory Core short-term recall: upgrades from pre-July-2026 dreaming JSON are no longer migrated
    Failing check sessions (blocked-by-prior-refusal): Migration step "sessions" was not run because prior step "plugin-doctor-state" refused execution.
    """

    Agent.update(agent, &Map.put(&1, :doctor, refusal))

    assert {:error, {{:doctor_refused, reason}, installed: "2026.10.4"}} =
             Provisioner.upgrade_openclaw(
               user,
               opts(verify: fn _ -> {:error, %{original: :timeout}} end)
             )

    assert reason =~ "Doctor stopped"
    assert reason =~ "Failing check sessions"
    assert Accounts.get_user!(user.id).openclaw_version == "2026.4.9"
  end

  test "a doctor that only warns does not change a good verdict", %{user: user, agent: agent} do
    Agent.update(
      agent,
      &Map.put(&1, :doctor, "Doctor warnings: memory search key missing\nDoctor complete.\n")
    )

    assert {:ok, "2026.10.4"} = Provisioner.upgrade_openclaw(user, opts())
  end

  test "a floating tag is refused: the result must be checkable", %{user: user} do
    assert {:error, {:pin_an_exact_version, "latest"}} =
             Provisioner.upgrade_openclaw(user, opts(version: "latest"))
  end

  test "the fleet pass takes the named poets only", %{user: user, agent: agent} do
    other = agent_user_fixture(%{sprite_name: "sandbox-test-8"})

    assert [{email, {:ok, "2026.10.4"}}] =
             Provisioner.upgrade_openclaw_fleet(opts(only: [user.email], stagger_ms: 0))

    assert email == user.email
    refute Enum.any?(calls(agent), &match?({:stop, "sandbox-test-8", _}, &1))

    assert [{_, {:ok, _}}] =
             Provisioner.upgrade_openclaw_fleet(opts(exclude: [user.email], stagger_ms: 0))

    assert Accounts.get_user!(other.id).openclaw_version == "2026.10.4"
  end

  test "release arithmetic" do
    assert Provisioner.parse_openclaw_version("OpenClaw 2026.10.4 (383c124)\n") == "2026.10.4"
    assert Provisioner.parse_openclaw_version("2026.10.10-beta.1") == "2026.10.10-beta.1"
    assert Provisioner.parse_openclaw_version("") == nil
    assert Provisioner.older_release?("2026.4.9", "2026.7.1")
    assert Provisioner.older_release?("2026.9.33", "2026.10.4")
    refute Provisioner.older_release?("2026.10.4", "2026.9.5")
    assert Provisioner.resolve_openclaw_npm_version("2026.9.5") == "2026.9.5"
    assert Provisioner.resolve_openclaw_npm_version("stable") =~ ~r/^\d{4}\.\d+\.\d+$/
  end
end
