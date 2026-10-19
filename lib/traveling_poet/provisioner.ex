defmodule TravelingPoet.Provisioner do
  @moduledoc """
  Provisions a poet's sprites.dev sandbox: creates the sprite, installs the
  OpenClaw agent, writes its config/env/workspace, installs the tpoet plugin
  (the agent's journal write-back tools), starts the gateway service, and
  pairs the Ed25519 device used by GatewaySocket.

  Ported from alice-in-goals' Provisioner core; all battery/bldg steps
  dropped. Idempotent — safe to re-run for an existing user.
  """

  require Logger

  alias TravelingPoet.{Accounts, GatewaySocket, SpritesClient}

  @gateway_port 8080
  @workspace "~/.openclaw/workspace"

  # Workspace content embedded at compile time. Edits to these files need
  # `mix compile --force` (or touching this module) to reach new provisions.
  @agents_path "priv/data/AGENTS.md"
  @external_resource @agents_path
  @agents_md File.read!(@agents_path)

  @heartbeat_path "priv/data/HEARTBEAT.md"
  @external_resource @heartbeat_path
  @heartbeat_md File.read!(@heartbeat_path)

  @skill_names ~w(travel-and-journal discover poem chat-companion onboard revise-entry compose-book)
  # Every .md in a skill's folder ships: SKILL.md, plus the day files a long
  # skill hands off to (travel-and-journal's scout.md, excursion.md,
  # asking.md), read only on the days they apply.
  @skill_contents (for skill <- @skill_names,
                       path <- Path.wildcard("priv/data/skills/#{skill}/*.md"),
                       into: %{} do
                     Module.put_attribute(__MODULE__, :external_resource, path)
                     {"#{skill}/#{Path.basename(path)}", File.read!(path)}
                   end)

  @doc false
  def skill_files, do: @skill_contents

  @doc """
  Derives a user's default sprite name, namespaced per environment so prod and
  dev (separate DBs reusing the same id sequence, sharing one sprites.dev
  account) can't collide. Controlled by `SPRITE_NAMESPACE` (default "tpoet").
  """
  def default_sprite_name(user_id) do
    case Application.get_env(:traveling_poet, :sprite_namespace) || "tpoet" do
      "" -> "sandbox-#{user_id}"
      ns -> "sandbox-#{ns}-#{user_id}"
    end
  end

  def openrouter_model do
    Application.get_env(:traveling_poet, :openrouter_model, "anthropic/claude-sonnet-4.6")
  end

  @doc """
  The OpenRouter key is a hard prerequisite: openclaw.json references
  ${OPENROUTER_API_KEY}, and the gateway refuses to start when a referenced
  secret is empty — the service just crash-loops. Fail before touching the
  sprite instead.
  """
  def missing_prerequisites do
    for {key, env} <- [
          {:sprites_token, "SPRITES_TOKEN"},
          {:openrouter_api_key, "OPENROUTER_API_KEY"}
        ],
        Application.get_env(:traveling_poet, key) in [nil, ""],
        do: env
  end

  # The provisioning chain, in order. The journal's setup card groups these
  # into the four things a reader can picture; keep the order in sync with the
  # `with` in do_provision_user/2.
  @steps ~w(create_sprite make_public install_openclaw write_config prepare_state
            write_env write_workspace write_tpoet_plugin pair_device import_pairing
            ensure_gateway_service get_sprite_url)a

  @doc "The provisioning steps in the order they run."
  def steps, do: @steps

  # Announce a step before running it, so a watching journal can show
  # progress. Purely cosmetic: `{:sprite_provisioned, _}` and the user row
  # remain the source of truth, and a tab that misses a step loses nothing.
  defp step(user_id, name, fun) when name in @steps do
    Phoenix.PubSub.broadcast(TravelingPoet.PubSub, "user:#{user_id}", {:provision_step, name})
    fun.()
  end

  @doc """
  Provisions (or re-provisions) the user's sprite in a background task and
  returns immediately. LiveViews call this after onboarding and mode switches;
  `config :traveling_poet, provision_in_background: false` (test) makes it a
  no-op so the suite never reaches a real sprite.
  """
  def provision_in_background(user) do
    if Application.get_env(:traveling_poet, :provision_in_background, true) do
      Task.start(fn ->
        case provision_user(user) do
          {:ok, _} -> :ok
          {:error, reason} -> Logger.error("Provisioning failed: #{inspect(reason)}")
        end
      end)
    end

    :ok
  end

  def provision_user(user, opts \\ []) do
    case missing_prerequisites() do
      [] -> do_provision_user(user, opts)
      missing -> {:error, {:missing_env, missing}}
    end
  end

  defp do_provision_user(%{id: user_id} = user, opts) do
    sprite_name = user.sprite_name || default_sprite_name(user_id)
    gateway_token = Keyword.get(opts, :gateway_token, user.gateway_token || generate_token())
    agent_api_token = user.agent_api_token || "#{user_id}.#{generate_token()}"
    agent_name = Keyword.get(opts, :agent_name, user.agent_name || "poet")
    openclaw_version = Keyword.get(opts, :openclaw_version, "stable")
    poet = TravelingPoet.Poets.get_poet_by_user(user_id)

    Logger.info("Provisioning sprite #{sprite_name} for user #{user_id}")

    # Reuse existing device keys (like the tokens above): regenerating on
    # every re-provision rewrites the sprite's paired.json and instantly
    # invalidates any live GatewaySocket still authenticated with the old
    # keys ("Authentication failed: pairing required").
    {device_pub, device_priv} =
      if user.device_public_key && user.device_private_key do
        {user.device_public_key, user.device_private_key}
      else
        GatewaySocket.generate_device_keys()
      end

    phoenix_url = Application.get_env(:traveling_poet, :phoenix_url, "http://localhost:4000")

    with {:ok, _} <- step(user_id, :create_sprite, fn -> create_sprite(sprite_name) end),
         {:ok, _} <- step(user_id, :make_public, fn -> make_public(sprite_name) end),
         {:ok, _} <-
           step(user_id, :install_openclaw, fn ->
             install_openclaw(sprite_name, openclaw_version)
           end),
         {:ok, _} <-
           step(user_id, :write_config, fn ->
             write_config(sprite_name, gateway_token, phoenix_url, poet_model(poet))
           end),
         {:ok, _} <- step(user_id, :prepare_state, fn -> prepare_state(sprite_name) end),
         {:ok, _} <-
           step(user_id, :write_env, fn ->
             write_env(sprite_name, gateway_token, agent_api_token, phoenix_url)
           end),
         {:ok, _} <-
           step(user_id, :write_workspace, fn ->
             write_workspace(sprite_name, agent_name, user, poet)
           end),
         {:ok, _} <-
           step(user_id, :write_tpoet_plugin, fn ->
             write_tpoet_plugin(sprite_name, phoenix_url, agent_api_token)
           end),
         {:ok, _} <- step(user_id, :pair_device, fn -> pair_device(sprite_name, device_pub) end),
         {:ok, _} <- step(user_id, :import_pairing, fn -> import_pairing(sprite_name) end),
         {:ok, _} <-
           step(user_id, :ensure_gateway_service, fn -> ensure_gateway_service(sprite_name) end),
         {:ok, sprite_url} <-
           step(user_id, :get_sprite_url, fn -> SpritesClient.get_sprite_url(sprite_name) end) do
      {:ok, _updated_user} =
        Accounts.update_user(user, %{
          sprite_name: sprite_name,
          sprite_url: sprite_url,
          gateway_token: gateway_token,
          agent_api_token: agent_api_token,
          agent_name: agent_name,
          sprite_provisioned: true,
          device_public_key: device_pub,
          device_private_key: device_priv,
          openclaw_version: resolve_openclaw_npm_version(openclaw_version)
        })

      if poet, do: TravelingPoet.Poets.update_poet(poet, %{status: "active"})

      result = %{sprite_name: sprite_name, sprite_url: sprite_url, gateway_token: gateway_token}

      Phoenix.PubSub.broadcast(
        TravelingPoet.PubSub,
        "user:#{user_id}",
        {:sprite_provisioned, result}
      )

      Logger.info("Provisioned #{sprite_name} at #{sprite_url}")
      {:ok, result}
    else
      {:error, reason} = err ->
        Logger.error("Provisioning failed for #{sprite_name}: #{inspect(reason)}")
        if poet, do: TravelingPoet.Poets.update_poet(poet, %{status: "error"})
        err
    end
  end

  def deprovision_user(%{id: user_id} = user) do
    sprite_name = user.sprite_name || default_sprite_name(user_id)

    with {:ok, _} <- SpritesClient.delete_sprite(sprite_name) do
      Accounts.update_user(user, %{
        sprite_name: nil,
        sprite_url: nil,
        gateway_token: nil,
        agent_api_token: nil,
        sprite_provisioned: false
      })

      :ok
    end
  end

  @doc """
  Gives a poet a fresh conversation: stops the gateway, sets the session
  files aside (kept as `sessions-reset-<unix time>`, never deleted), starts
  it again. The workspace (skills, memory) is untouched.

  For a retry of entry #0: Kenji Driftwood's second attempt (2026-09-30)
  inherited the derailed first one, overflowed its context at 64 messages
  and sat idle; a fresh conversation published the page in ten minutes.
  """
  def fresh_conversation(user) do
    do_fresh_conversation(user)
  end

  @doc """
  `fresh_conversation/1` before a retry, then a pause for the gateway to take
  connections again. Used by every retry of an agent turn that failed
  (`FirstEntry`, `DailyJourneyScheduler`): a retry inside the conversation
  that failed inherits whatever broke it. One poet, 2026-09-30: the
  first run overflowed its context re-reading its skill, and both retries
  continued the same overflowed session. Off in test (`:fresh_start_on_retry`),
  where there is no sprite to restart.
  """
  def fresh_start(user) do
    if Application.get_env(:traveling_poet, :fresh_start_on_retry, true) do
      case fresh_conversation(user) do
        :ok ->
          Logger.info("Provisioner: fresh conversation for user #{user.id} before a retry")
          Process.sleep(Application.get_env(:traveling_poet, :gateway_boot_ms, 10_000))
          :ok

        other ->
          Logger.warning(
            "Provisioner: fresh conversation failed for user #{user.id}: #{inspect(other)}"
          )

          other
      end
    else
      :skipped
    end
  end

  # Two layouts: OpenClaw up to 2026.4 kept one JSONL file per session under
  # `agents/main/sessions/`; since 2026.10 the whole conversation store is
  # the agent database `agents/main/agent/openclaw-agent.sqlite` (with its
  # -wal and -shm), recreated empty by the next gateway start. Both are set
  # aside, never deleted; `instructions.md` and `workshop-skills/` beside the
  # database stay, they are not conversation.
  defp do_fresh_conversation(user) do
    name = user.sprite_name || default_sprite_name(user.id)
    sessions = "~/.openclaw/agents/main/sessions"
    agent_db = "~/.openclaw/agents/main/agent/openclaw-agent.sqlite"
    client = Application.get_env(:traveling_poet, :sprites_client, SpritesClient)

    with {:ok, _} <- client.stop_service(name, "openclaw-gateway"),
         {:ok, _} <-
           client.exec(
             name,
             "ts=$(date +%s); mkdir -p #{sessions}-reset-$ts && " <>
               "mv #{sessions}/* #{sessions}-reset-$ts/ 2>/dev/null; " <>
               "mv #{agent_db} #{agent_db}-wal #{agent_db}-shm #{sessions}-reset-$ts/ 2>/dev/null; true"
           ),
         {:ok, _} <- client.start_service(name, "openclaw-gateway") do
      :ok
    end
  end

  @doc """
  Repacks a provisioned poet for a new mission (Settings' mode switch), in
  the background.

  The switch used to re-provision the whole sprite, running doctor and the
  plugin install against the live gateway. On 2026-10-18 that met a poet
  whose gateway held the state database ("Doctor could not enter
  maintenance"), failed, and set the poet to "error", which the daily
  scheduler skips: a working poet went a day without a page. The mission and
  its model live in openclaw.json and the persona files, so
  `upgrade_workspace/1` carries them, with the gateway stopped first. It
  waits while a turn is running (up to `:tries` × `:wait_ms`, then goes
  ahead), pages the admins on failure, and never touches the poet's status.

  Options (for tests): `:busy?`, `:upgrade`, `:wait_ms`, `:tries`.
  """
  def repack_in_background(user, opts \\ []) do
    if Application.get_env(:traveling_poet, :provision_in_background, true) do
      Task.start(fn -> repack(user, opts) end)
    end

    :ok
  end

  @repack_wait_ms 2 * 60 * 1000
  @repack_tries 15

  @doc false
  def repack(user, opts \\ []) do
    busy? = Keyword.get(opts, :busy?, &TravelingPoet.Markers.Delivery.busy?/1)
    upgrade = Keyword.get(opts, :upgrade, &upgrade_workspace/1)
    wait_ms = Keyword.get(opts, :wait_ms, @repack_wait_ms)
    tries = Keyword.get(opts, :tries, @repack_tries)

    if tries > 0 and busy?.(user.id) do
      Process.sleep(wait_ms)
      repack(user, Keyword.put(opts, :tries, tries - 1))
    else
      case upgrade.(user) do
        {:ok, _} = ok ->
          ok

        {:error, reason} = err ->
          Logger.error("Repack failed for user #{user.id}: #{inspect(reason)}")

          TravelingPoet.Alerts.notify_admins(
            "Repack for a new mission failed for user #{user.id}: #{inspect(reason)}"
          )

          err
      end
    end
  end

  @doc """
  Re-seed workspace files (skills/AGENTS/scripts) AND the tool plugin on an
  existing sprite.

  The plugin used to be written only by `do_provision_user/2`, so a poet
  provisioned last week could never gain a new tool — the app would ship an
  endpoint no agent knew how to call. Rewriting it here makes this the light
  way to roll changes across the fleet: full re-provisioning re-runs npm
  checks, device pairing and service teardown, which is a lot of risk to take
  on eight live sprites just to deliver a skill edit.

  The gateway is stopped BEFORE the plugin is installed, and started after.
  On OpenClaw 2026.10 `plugins install` into a running gateway hot-reloads
  it and waits up to 60s for the work it admitted to drain; on the
  2026-10-19 rollout 16 of 36 poets timed out there ("the previous plugin
  generation stays active"), and the restart after it never ran. A plugin
  whose fingerprint on the sprite already matches is left alone
  (`ensure_plugin/3`), so a skill-only rollout does not touch it.

  Note skills are compile-time embedded (`@skill_contents`), so editing a
  SKILL.md needs `mix compile --force` before this will carry the new text.
  """
  def upgrade_workspace(user) do
    sprite_name = user.sprite_name || default_sprite_name(user.id)
    poet = TravelingPoet.Poets.get_poet_by_user(user.id)
    phoenix_url = Application.get_env(:traveling_poet, :phoenix_url, "http://localhost:4000")

    with {:ok, _} <- refresh_config(sprite_name, user, phoenix_url, poet),
         {:ok, _} <- write_workspace(sprite_name, user.agent_name || "poet", user, poet),
         # nothing running, so nothing for the install to drain; a gateway
         # already stopped (an upgrade stops it first) answers 409
         _ <- client().stop_service(sprite_name, "openclaw-gateway"),
         {:ok, _} <- ensure_plugin(sprite_name, phoenix_url, user.agent_api_token),
         {:ok, _} <- ensure_gateway_service(sprite_name) do
      {:ok, sprite_name}
    end
  end

  @doc """
  Rolls workspace + plugin changes across every provisioned poet, staggered so
  the fleet doesn't hammer the sprites API. Returns `{email, result}` per
  user, the result one of:

    * `:ok`: rewritten, restarted, and the app's own socket got `hello-ok`
      back (`verify_gateway/1`);
    * `:skipped_busy`: a run was in progress (`Markers.Delivery.busy?/3`: a
      daily page, first page, revision or book in the last 15 minutes, a
      chat turn in the last 5), so its gateway was left alone; run again
      later for those (card-77);
    * `{:error, reason}`.

  Options: `:stagger_ms`, `:users` (default every provisioned user),
  `:force` (ignore busy), and `:workspace`, `:verify`, `:busy?` to swap the
  steps in tests.
  """
  def upgrade_fleet(opts \\ []) do
    stagger_ms = Keyword.get(opts, :stagger_ms, 3_000)
    users = Keyword.get_lazy(opts, :users, &TravelingPoet.Accounts.list_provisioned_users/0)

    Enum.map(users, fn user ->
      result = upgrade_one(user, opts)
      if result != :skipped_busy, do: Process.sleep(stagger_ms)
      Logger.info("Provisioner: fleet upgrade, user #{user.id}: #{inspect(result)}")
      {user.email, result}
    end)
  end

  defp upgrade_one(user, opts) do
    workspace = Keyword.get(opts, :workspace, &upgrade_workspace/1)
    verify = Keyword.get(opts, :verify, &verify_gateway/1)
    busy? = Keyword.get(opts, :busy?, &TravelingPoet.Markers.Delivery.busy?/1)

    if not Keyword.get(opts, :force, false) and busy?.(user.id) do
      :skipped_busy
    else
      with {:ok, _} <- workspace.(user),
           :ok <- verify.(user) do
        :ok
      else
        {:error, _} = error -> error
        other -> {:error, other}
      end
    end
  end

  @doc """
  Moves one provisioned poet to another OpenClaw release, in place.

  The fleet was pinned to 2026.4.9 from the first build while OpenClaw moved
  on (protocol v4 gateways, Node 24.16+, SQLite-backed state), so this is the
  path that carries a live sprite across, and it is written to leave the poet
  on a working release whatever happens:

    1. a poet in the middle of a run is skipped (`Markers.Delivery.busy?/3`:
       a daily page, first page, revision or book in the last 15 minutes, a
       chat turn in the last 5) unless `force: true`;
    2. the gateway is stopped and the sprite held awake;
    3. optionally a bridge release first (`bridge: :auto` applies OpenClaw's
       rule for installs older than July 2026, `bridge: "2026.9.5"` forces
       one; off by default, see `bridge_release/3`), with its own doctor run;
    4. the target release is installed and must report itself as
       `openclaw --version`;
    5. the config is rewritten, `openclaw doctor --fix --non-interactive`
       migrates the stored state (pairing, sessions), `upgrade_workspace/1`
       rewrites workspace and plugin and starts the gateway;
    6. the app's own socket must authenticate (`verify_gateway/1`) before the
       release is recorded on the user.

  A failed install puts the previous release back and restarts its gateway.
  A failed handshake after the install leaves the sprite on the new release
  (doctor has migrated its state by then; going back is not an option) and
  the release unrecorded, so the next pass only redoes the last phase.
  Options: `:version` (an npm version or "stable", default "stable"),
  `:force`, `:bridge`, `:install_timeout_ms`.

  Returns `{:ok, version}`, `{:ok, :already_current}`, `{:skipped, :busy}` or
  `{:error, reason}`.
  """
  def upgrade_openclaw(user, opts \\ []) do
    target = resolve_openclaw_npm_version(Keyword.get(opts, :version, "stable"))
    force? = Keyword.get(opts, :force, false)
    sprite_name = user.sprite_name || default_sprite_name(user.id)

    cond do
      parse_openclaw_version(target) != target ->
        {:error, {:pin_an_exact_version, target}}

      not force? and TravelingPoet.Markers.Delivery.busy?(user.id) ->
        {:skipped, :busy}

      true ->
        installed = installed_openclaw_version(sprite_name)

        cond do
          installed == target and user.openclaw_version == target and not force? ->
            {:ok, :already_current}

          installed == target and not force? ->
            # The package is there but the pass that put it never got to
            # record it (a handshake that failed, an interrupted rpc): only
            # the last phase is owed.
            TravelingPoet.SpriteHold.with_hold(sprite_name, "upgrade", fn ->
              client().stop_service(sprite_name, "openclaw-gateway")
              finish_upgrade(user, sprite_name, target, opts)
            end)

          true ->
            TravelingPoet.SpriteHold.with_hold(sprite_name, "upgrade", fn ->
              do_upgrade_openclaw(user, sprite_name, installed, target, opts)
            end)
        end
    end
  end

  @bridge_release "2026.9.5"
  # Releases before this one keep state the current line no longer imports
  # directly (see "Upgrading very old versions" in OpenClaw's updating guide).
  @bridge_needed_before "2026.7.1"

  # Phases, because what a failure may undo depends on where it happens.
  # Until doctor has migrated state at a newer release, npm leaves the old
  # package tree intact on a failed install and the poet can simply be put
  # back on it. Once doctor has run at a release, that release is the floor:
  # OpenClaw's updating guide is explicit that a package rollback cannot
  # undo migrated state (a 2026.4.9 gateway restarted on a store its
  # successor had migrated answered "pairing required" to everything,
  # probe sprite, 2026-10-16). So after the target's doctor the sprite stays
  # on the target whatever the handshake says, the release is left
  # unrecorded, and the next pass picks it up from there.
  defp do_upgrade_openclaw(user, sprite_name, installed, target, opts) do
    bridge = bridge_release(installed, target, Keyword.get(opts, :bridge, false))

    Logger.info(
      "Provisioner: upgrading OpenClaw on #{sprite_name} #{installed || "none"} -> #{target}" <>
        if(bridge, do: " via #{bridge}", else: "")
    )

    with {:ok, _} <- client().stop_service(sprite_name, "openclaw-gateway"),
         {:ok, floor} <- bridge_step(user, sprite_name, bridge, opts),
         :ok <- install_or_restore(user, sprite_name, target, floor || installed, opts) do
      finish_upgrade(user, sprite_name, target, opts)
    end
  end

  defp bridge_step(_user, _sprite_name, nil, _opts), do: {:ok, nil}

  defp bridge_step(user, sprite_name, bridge, opts) do
    case install_openclaw_release(sprite_name, bridge, opts) do
      :ok ->
        refresh_config_for(user)
        doctor_fix(sprite_name)
        {:ok, bridge}

      {:error, reason} ->
        restore_release(user, sprite_name, installed_openclaw_version(sprite_name), reason, opts)
    end
  end

  defp install_or_restore(user, sprite_name, target, previous, opts) do
    case install_openclaw_release(sprite_name, target, opts) do
      :ok -> :ok
      {:error, reason} -> restore_release(user, sprite_name, previous, reason, opts)
    end
  end

  # Config first so doctor migrates against the current release's shape of
  # it, then doctor for the stored state, then the workspace and plugin and
  # the gateway start, then the app's own handshake as the verdict.
  defp finish_upgrade(user, sprite_name, target, opts) do
    workspace = Keyword.get(opts, :workspace, &upgrade_workspace/1)
    verify = Keyword.get(opts, :verify, &verify_gateway/1)

    refresh_config_for(user)
    doctor = doctor_fix(sprite_name)

    with {:ok, _} <- workspace.(user),
         :ok <- verify.(user) do
      record_openclaw_version(user, target)
      {:ok, target}
    else
      error ->
        # A refused migration is the reason the handshake failed, so it is
        # the reason reported; the handshake's own timeout says nothing.
        reason =
          case doctor do
            {:error, refusal} -> refusal
            :ok -> unwrap_error(error)
          end

        Logger.error(
          "Provisioner: #{sprite_name} is on OpenClaw #{target} but the app could not confirm it (#{inspect(reason)}); left there, unrecorded"
        )

        {:error, {reason, installed: target}}
    end
  end

  defp refresh_config_for(user) do
    sprite_name = user.sprite_name || default_sprite_name(user.id)
    poet = TravelingPoet.Poets.get_poet_by_user(user.id)
    phoenix_url = Application.get_env(:traveling_poet, :phoenix_url, "http://localhost:4000")
    refresh_config(sprite_name, user, phoenix_url, poet)
  end

  defp unwrap_error({:error, reason}), do: reason
  defp unwrap_error(other), do: other

  # Nothing was migrated at a newer release yet: the previous package goes
  # back (npm keeps it when an install fails, so usually it is still there)
  # and the gateway restarts on it.
  defp restore_release(user, sprite_name, previous, reason, opts) do
    workspace = Keyword.get(opts, :workspace, &upgrade_workspace/1)
    verify = Keyword.get(opts, :verify, &verify_gateway/1)

    Logger.error(
      "Provisioner: OpenClaw upgrade on #{sprite_name} failed (#{inspect(reason)}), back to #{previous || "nothing"}"
    )

    restored =
      with true <- is_binary(previous),
           :ok <- ensure_release(sprite_name, previous, opts),
           {:ok, _} <- workspace.(user),
           :ok <- verify.(user) do
        record_openclaw_version(user, previous)
        :ok
      else
        false -> {:error, :no_previous_release}
        error -> error
      end

    Logger.error(
      "Provisioner: #{sprite_name} back on #{previous || "nothing"}: #{inspect(restored)}"
    )

    {:error, {reason, rolled_back: restored}}
  end

  defp ensure_release(sprite_name, version, opts) do
    if installed_openclaw_version(sprite_name) == version,
      do: :ok,
      else: install_openclaw_release(sprite_name, version, opts)
  end

  @bridge_release "2026.9.5"
  # Releases before this one keep state the current line no longer imports
  # directly (see "Upgrading very old versions" in OpenClaw's updating guide).
  # Off by default: the direct move from 2026.4.9 to 2026.10.4 imports the
  # pairing and sessions a poet's sprite holds (probe sprites, 2026-10-16),
  # and the bridge's second install failed once for reasons npm's rotated
  # log no longer held. `bridge: :auto` applies the guide's rule.
  @bridge_needed_before "2026.7.1"

  defp bridge_release(_installed, _target, false), do: nil
  defp bridge_release(_installed, _target, version) when is_binary(version), do: version

  defp bridge_release(installed, target, :auto) do
    if is_binary(installed) and older_release?(installed, @bridge_needed_before) and
         older_release?(@bridge_release, target),
       do: @bridge_release,
       else: nil
  end

  @doc "True when release `a` (\"2026.4.9\") is older than release `b`."
  def older_release?(a, b) when is_binary(a) and is_binary(b) do
    release_tuple(a) < release_tuple(b)
  end

  defp release_tuple(version) do
    version
    |> String.split("-", parts: 2)
    |> hd()
    |> String.split(".")
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, _} -> n
        :error -> 0
      end
    end)
    |> List.to_tuple()
  end

  # Doctor's job here is the stored state (sessions, pairing, plugin state,
  # retired config keys); its verdict on openclaw.json and the plugin does
  # not matter because both are rewritten right after. It never fails the
  # upgrade, but what it said is kept in the log for the operator.
  # Doctor's exit code says nothing: it exits 0 after "Doctor stopped because
  # a state migration refused to continue". One poet (2026-10-16) had its
  # session store left unmigrated that way, the gateway then exited 78 on
  # every start, and the upgrade reported a handshake timeout instead of
  # the refusal. The step still never stops an upgrade on its own (a noisy
  # doctor is the norm); it returns the refusal so the verdict can name it.
  defp doctor_fix(sprite_name) do
    cmd =
      "timeout 300 $(npm prefix -g)/bin/openclaw doctor --fix --non-interactive 2>&1 | tail -c 2500"

    case client().exec(sprite_name, cmd) do
      {:ok, out} ->
        text = extract_text(out)
        Logger.info("Provisioner: doctor --fix on #{sprite_name}:\n#{text}")

        case doctor_refusal(text) do
          nil ->
            :ok

          refusal ->
            Logger.error("Provisioner: doctor --fix on #{sprite_name} refused: #{refusal}")
            {:error, {:doctor_refused, refusal}}
        end

      {:error, reason} ->
        Logger.warning("Provisioner: doctor --fix on #{sprite_name} failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc false
  # The lines that name what doctor would not do, or nil when it finished.
  # "Doctor stopped" heads a refused migration, "Failing check" lists the
  # steps it skipped, "Invalid config" / "config is invalid" is a file the
  # current release will not read at all.
  def doctor_refusal(text) when is_binary(text) do
    refused? =
      text =~ "Doctor stopped" or text =~ "Failing check" or text =~ ~r/invalid config/i or
        text =~ ~r/config is invalid/i

    if refused? do
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(fn line ->
        line =~ "Doctor stopped" or line =~ "Failing check" or line =~ ~r/invalid config/i or
          line =~ ~r/config is invalid/i or line =~ ~r/^- /
      end)
      |> Enum.take(6)
      |> Enum.join(" | ")
      |> String.slice(0, 600)
    end
  end

  defp record_openclaw_version(user, version) do
    case Accounts.update_user(user, %{openclaw_version: version}) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "Provisioner: could not record OpenClaw #{version} on user #{user.id}: #{inspect(changeset.errors)}"
        )
    end
  end

  @doc """
  Proof that the app can still talk to the poet: a fresh socket must reach
  `hello-ok` on the new gateway. The socket is closed again afterwards so the
  sprite can go back to sleep.
  """
  def verify_gateway(user, timeout_ms \\ 90_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    user = Accounts.get_user(user.id) || user
    do_verify_gateway(user, deadline)
  end

  # A gateway answers "gateway starting; retry shortly" (close 1013) for a
  # few seconds after its service starts; that is a wait, not a verdict.
  defp do_verify_gateway(user, deadline) do
    TravelingPoet.GatewaySocketSupervisor.disconnect(user.id)
    remaining = max(deadline - System.monotonic_time(:millisecond), 1_000)

    result =
      with {:ok, pid} <- TravelingPoet.GatewaySocketSupervisor.ensure_connected(user, attempts: 8) do
        GatewaySocket.subscribe(pid)
        GatewaySocket.request_status(pid)

        outcome =
          receive do
            {:gateway_status, :authenticated} -> :ok
            {:gateway_event, :connected} -> :ok
            {:gateway_event, {:error, reason}} -> {:error, {:gateway, reason}}
          after
            remaining -> {:error, :gateway_handshake_timeout}
          end

        GatewaySocket.unsubscribe(pid)
        outcome
      end

    TravelingPoet.GatewaySocketSupervisor.disconnect(user.id)

    case result do
      {:error, {:gateway, reason}} when is_binary(reason) ->
        if reason =~ "starting" and System.monotonic_time(:millisecond) < deadline do
          Process.sleep(3_000)
          do_verify_gateway(user, deadline)
        else
          result
        end

      other ->
        other
    end
  end

  @doc """
  Rolls `upgrade_openclaw/2` across the fleet, one poet after another: each
  install is minutes of CPU and network on its sprite, and the sprites API is
  shared, so there is no parallelism on purpose. Busy poets are skipped and
  come back in the result so a second pass can take them. `only: [emails]`
  restricts a pass (the way to try one poet first), `exclude: [emails]`
  keeps named poets out; other options pass through to `upgrade_openclaw/2`.
  Returns `{email, result}` per poet.
  """
  def upgrade_openclaw_fleet(opts \\ []) do
    stagger_ms = Keyword.get(opts, :stagger_ms, 10_000)
    only = Keyword.get(opts, :only)
    exclude = Keyword.get(opts, :exclude, [])

    Accounts.list_provisioned_users()
    |> Enum.filter(fn user ->
      (only == nil or user.email in only) and user.email not in exclude
    end)
    |> Enum.map(fn user ->
      result = upgrade_openclaw(user, opts)
      Logger.info("Provisioner: OpenClaw upgrade for #{user.email}: #{inspect(result)}")
      Process.sleep(stagger_ms)
      {user.email, result}
    end)
  end

  @doc """
  `upgrade_openclaw_fleet/1` in a task of its own, for an `rpc` call that
  must return at once: hours of installs do not fit an SSH session. Progress
  shows in the logs and in `users.openclaw_version`; the admins are paged
  with the tally when the pass ends.
  """
  def start_openclaw_fleet_upgrade(opts \\ []) do
    Task.start(fn ->
      results = upgrade_openclaw_fleet(opts)

      summary =
        results
        |> Enum.map(fn {email, result} -> "#{email}: #{inspect(result, limit: 6)}" end)
        |> Enum.join("\n")

      TravelingPoet.Alerts.notify_admins("OpenClaw fleet upgrade finished:\n#{summary}")
    end)
  end

  # The gateway token is the sprite's auth secret; never rewrite the config
  # without it (a half-provisioned user would lock its own socket out).
  defp refresh_config(sprite_name, %{gateway_token: token}, phoenix_url, poet)
       when is_binary(token) and token != "" do
    write_config(sprite_name, token, phoenix_url, poet_model(poet))
  end

  defp refresh_config(sprite_name, _user, _phoenix_url, _poet) do
    Logger.warning(
      "Provisioner: #{sprite_name} has no gateway token, leaving openclaw.json as is"
    )

    {:ok, :skipped}
  end

  # -- internal steps --

  defp create_sprite(name) do
    case SpritesClient.get_sprite(name) do
      {:ok, _} ->
        Logger.info("Sprite #{name} already exists, skipping creation")
        {:ok, :already_exists}

      _ ->
        Logger.info("Creating sprite #{name}")
        SpritesClient.create_sprite(name)
    end
  end

  defp make_public(name) do
    SpritesClient.update_sprite(name, %{auth: "public"})
  end

  # A provisioned sprite always ends on the release asked for: a re-provision
  # (mode switch, token rotation) of a poet still on an older release moves
  # it, since the config, plugin manifest and pairing import written next
  # are the current release's shape. `import_pairing` runs doctor for its
  # state migrations right after.
  @doc false
  def install_openclaw(name, openclaw_version, opts \\ []) do
    npm_version = resolve_openclaw_npm_version(openclaw_version)

    case installed_openclaw_version(name) do
      ^npm_version ->
        Logger.info("OpenClaw #{npm_version} already installed in #{name}, skipping")
        {:ok, :already_installed}

      nil ->
        do_install_openclaw(name, npm_version, opts)

      installed ->
        Logger.info("OpenClaw #{installed} installed in #{name}, moving to #{npm_version}")
        client().stop_service(name, "openclaw-gateway")
        do_install_openclaw(name, npm_version, opts)
    end
  end

  @doc """
  The npm version a release name stands for: `"stable"` is the fleet pin
  (`OPENCLAW_STABLE_VERSION`), `"latest"` the npm tag, anything else an
  exact version such as `"2026.10.4"`.
  """
  def resolve_openclaw_npm_version("stable") do
    Application.get_env(:traveling_poet, :openclaw_stable_version, "2026.10.4")
  end

  def resolve_openclaw_npm_version(version) when is_binary(version), do: version

  # A sprite runs only while something holds it: an exec call, a socket, a
  # task. The install below is detached from the exec that starts it, so
  # without a hold npm gets a sliver of CPU on each ten second poll and
  # nothing in between. The first three sign-ups after the detached install
  # shipped (2026-10-17, users 39 to 41) each had npm alive and crawling
  # (85 MB of a 600 MB release after half an hour) when the poll gave up,
  # and the poet ended in "error". The fleet upgrade already ran under a
  # hold, which is why its installs took eight minutes.
  defp do_install_openclaw(name, npm_version, opts) do
    TravelingPoet.SpriteHold.with_hold(name, "install", fn ->
      with :ok <- install_openclaw_release(name, npm_version, opts) do
        client().exec(name, "mkdir -p #{@workspace}/memory")
      end
    end)
  end

  @install_log "/tmp/tpoet-openclaw-install.log"
  @install_timeout_ms 20 * 60 * 1000
  @install_poll_ms 10_000

  # `npm install -g openclaw@<version>` on a sprite: a release is ~600 MB
  # and 300+ packages, eight minutes on a cold npm cache (2026-10-16), far
  # past the two minutes one exec call may take. So the install is started
  # detached from the exec session (`setsid nohup`, which the sprite keeps
  # running after the call returns) and polled until npm exits, then the
  # binary itself is asked which release it is. The caller holds the sprite
  # awake meanwhile. npm 12 (and 11.16+) refuse lifecycle scripts unless
  # named, and OpenClaw's postinstall is what wires its bundled plugins, so
  # the documented `--allow-scripts=openclaw` is added where npm knows it.
  defp install_openclaw_release(name, version, opts) do
    timeout_ms = Keyword.get(opts, :install_timeout_ms, @install_timeout_ms)
    poll_ms = Keyword.get(opts, :install_poll_ms, @install_poll_ms)
    Logger.info("Installing OpenClaw #{version} in #{name}")

    cmd =
      "rm -f #{@install_log}; setsid nohup npm install -g openclaw@#{version}" <>
        "#{npm_allow_scripts_flag(name)} --no-progress > #{@install_log} 2>&1 < /dev/null & " <>
        "echo started"

    with {:ok, _} <- client().exec(name, cmd) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      await_openclaw_install(name, version, deadline, poll_ms)
    end
  end

  defp await_openclaw_install(name, version, deadline, poll_ms) do
    Process.sleep(poll_ms)

    case client().exec(
           name,
           "pgrep -f 'npm install.*openclaw' > /dev/null && echo running || echo finished"
         ) do
      {:ok, out} ->
        running? = extract_text(out) =~ "running"

        cond do
          running? and System.monotonic_time(:millisecond) < deadline ->
            await_openclaw_install(name, version, deadline, poll_ms)

          running? ->
            {:error, {:install_timeout, version}}

          true ->
            case installed_openclaw_version(name) do
              ^version ->
                Logger.info("OpenClaw #{version} installed in #{name}")
                :ok

              other ->
                {:error, {:install_failed, version, other, install_log_tail(name)}}
            end
        end

      error ->
        error
    end
  end

  defp install_log_tail(name) do
    case client().exec(name, "tail -c 1500 #{@install_log} 2>/dev/null") do
      {:ok, out} -> extract_text(out)
      _ -> ""
    end
  end

  defp npm_allow_scripts_flag(name) do
    with {:ok, out} <- client().exec(name, "npm --version"),
         [major, minor | _] <- extract_text(out) |> String.trim() |> String.split("."),
         {major, ""} <- Integer.parse(major),
         {minor, ""} <- Integer.parse(minor),
         true <- major > 11 or (major == 11 and minor >= 16) do
      " --allow-scripts=openclaw"
    else
      _ -> ""
    end
  end

  @doc """
  The OpenClaw release installed on a sprite (`openclaw --version`, e.g.
  "2026.10.4"), or nil when there is none. The binary is not on the exec
  shell's PATH, so it is found through npm's global prefix.
  """
  def installed_openclaw_version(sprite_name) do
    case client().exec(sprite_name, "$(npm prefix -g)/bin/openclaw --version 2>/dev/null") do
      {:ok, out} -> parse_openclaw_version(extract_text(out))
      _ -> nil
    end
  end

  @doc "The release in an `openclaw --version` line (\"OpenClaw 2026.10.4 (383c124)\")."
  def parse_openclaw_version(text) when is_binary(text) do
    case Regex.run(~r/\b(\d{4}\.\d{1,2}\.\d{1,3}(?:-[0-9A-Za-z.]+)?)\b/, text) do
      [_, version] -> version
      _ -> nil
    end
  end

  def parse_openclaw_version(_), do: nil

  defp client do
    Application.get_env(:traveling_poet, :sprites_client, SpritesClient)
  end

  # OpenClaw's built-in provider catalog doesn't include OpenRouter; register
  # it as a custom OpenAI-compatible provider via models.providers.openrouter.
  # The literal ${OPENROUTER_API_KEY} placeholder is resolved by OpenClaw from
  # ~/.openclaw/.env at gateway startup — single-quoted heredoc in the exec
  # command keeps bash from substituting it here.
  # Model policy (takes effect on re-provision):
  #   1. explicit per-poet override (poet.settings["model"], an OpenRouter slug)
  #   2. scout mode -> the reliable model: scout entries inform real trip
  #      decisions, and the cheap fleet default has hallucination-shaped
  #      failure modes we can't afford there
  #   3. fleet default (OPENROUTER_MODEL)
  @doc "Resolves the model a poet runs on: explicit override > scout default > fleet default."
  def poet_model(poet) do
    cond do
      model = poet && get_in(poet.settings || %{}, ["model"]) ->
        model

      poet && TravelingPoet.Poets.Poet.mode(poet) == "scout" ->
        Application.get_env(:traveling_poet, :scout_model, "anthropic/claude-sonnet-4.6")

      true ->
        openrouter_model()
    end
  end

  @doc "The Perplexity model behind every poet's `web_search`."
  def search_model,
    do: Application.get_env(:traveling_poet, :search_model, "perplexity/sonar")

  @doc """
  The `~/.openclaw/openclaw.json` a poet runs with.

  The heartbeat is off (`every: "0m"`): a paused sprite has no clock, so it
  could only ever fire while the app is already driving a turn, where it
  costs a model call and its `HEARTBEAT_OK` races the real reply
  (`AgentSession`). Every cadence in this product lives app-side.

  `web_search` is pinned to Perplexity Sonar over the fleet OpenRouter key,
  model `search_model/0`. With nothing configured OpenClaw falls back to
  `perplexity/sonar-pro`; the 2026-09-18 replay of 50 real poet queries
  scored plain Sonar the same at half the price per call.
  """
  def openclaw_config(gateway_token, phoenix_url, model) do
    %{
      gateway: %{
        # The service passes --port/--bind too; the config copy is what
        # OpenClaw's own CLI (doctor, plugins, devices) reads to find it.
        port: @gateway_port,
        bind: "lan",
        controlUi: %{allowedOrigins: ["*", phoenix_url]},
        http: %{endpoints: %{responses: %{enabled: true}}},
        auth: %{token: gateway_token},
        # The app reaches the gateway through the sprite's public URL, so
        # every connection arrives from the sprites.app proxy (10.0.0.2 on
        # the sprite's private link) carrying X-Forwarded-For. OpenClaw
        # 2026.10 refuses such proxy-shaped traffic with 403
        # `proxy_attribution_required` unless the proxy is trusted; the
        # sprite's only peer on that network is the platform itself.
        trustedProxies: ["10.0.0.0/8"]
      },
      agents: %{defaults: %{model: "openrouter/#{model}", heartbeat: %{every: "0m"}}},
      plugins: %{
        # The allowlist gates OpenClaw's bundled plugins too: with only
        # tpoet-plugin allowed, an explicit perplexity provider is unavailable
        # and web_search falls through to Brave, which has no key.
        allow: ["tpoet-plugin", "perplexity"],
        # No apiKey: OpenClaw reads OPENROUTER_API_KEY from ~/.openclaw/.env.
        # Setting the model puts it on the Sonar chat-completions path.
        entries: %{
          "perplexity" => %{
            enabled: true,
            config: %{
              webSearch: %{baseUrl: "https://openrouter.ai/api/v1", model: search_model()}
            }
          }
        }
      },
      # OpenClaw 2026.10 hides tool schemas behind a "tool search" surface by
      # default ("cataloged 71 tools behind compact prompt surface"): the
      # model must search, describe, then call. The fleet model looped on it
      # and never reached journal_put_places (Udi's poet, 2026-10-16); direct
      # schemas are what every skill was written against.
      tools: %{web: %{search: %{provider: "perplexity"}}, toolSearch: false},
      # The same release learns "workshop skills" on its own: a background
      # review after ten model iterations and an unused-skill cleanup, both
      # model turns we did not ask for, the cleanup able to archive skills.
      skills: %{workshop: %{autonomous: %{mode: "off"}}},
      models: %{
        providers: %{
          "openrouter" => %{
            baseUrl: "https://openrouter.ai/api/v1",
            apiKey: "${OPENROUTER_API_KEY}",
            api: "openai-completions",
            models: [
              %{
                id: model,
                name: "#{model} (OpenRouter)",
                # reasoning: true is required for tool-calling on proxy routes
                # (verified empirically in alice-in-goals against custom
                # OpenAI-compatible providers)
                reasoning: true,
                # Text only, on purpose: the fleet model has no image-capable
                # endpoint on OpenRouter ("404 No endpoints found that support
                # image input"). OpenClaw 2026.10 honours this declaration and
                # sends every image part in a conversation to a model that
                # claims image input; one poet's chat died for a whole day on
                # a single image in its history (2026-10-16). Declared text
                # only, OpenClaw drops image parts instead.
                input: ["text"],
                contextWindow:
                  Application.get_env(:traveling_poet, :openrouter_context_window, 200_000),
                maxTokens: Application.get_env(:traveling_poet, :openrouter_max_tokens, 32_768)
              }
            ]
          }
        }
      }
    }
  end

  # Our settings go over whatever the file holds, never in place of it:
  # since 2026.4.22 a gateway treats a config that lost its `meta` block or
  # shrank sharply as clobbered and restores its last-known-good copy, and
  # doctor keeps its own keys there (meta, skills entries, migration marks).
  # Writing only our keys would have the gateway quietly undo a model or
  # token change. An unreadable file is replaced outright.
  defp write_config(name, gateway_token, phoenix_url, model) do
    ours = openclaw_config(gateway_token, phoenix_url, model)

    current =
      case client().exec(name, "cat ~/.openclaw/openclaw.json 2>/dev/null") do
        {:ok, out} ->
          case Jason.decode(extract_text(out)) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end

    config_json =
      current
      |> deep_merge(ours)
      |> scrub_legacy_config()
      |> Jason.encode!(pretty: true)

    cmd =
      "mkdir -p ~/.openclaw && cat > ~/.openclaw/openclaw.json << 'CONFIGEOF'\n#{config_json}\nCONFIGEOF"

    Logger.info("Writing config to #{name}")
    client().exec(name, cmd)
  end

  @doc false
  # Keys an older release wrote that the pinned one refuses: a merged file
  # keeps them, and OpenClaw 2026.10 then answers "Invalid config ... meta:
  # Unrecognized key: lastTouchedAt" to every CLI command, so the plugin
  # install fails (user 7, 2026-10-16). Doctor rewrites `meta` when it gets
  # that far; this makes sure the file is readable before it runs.
  def scrub_legacy_config(%{"meta" => meta} = config) when is_map(meta) do
    Map.put(config, "meta", Map.delete(meta, "lastTouchedAt"))
  end

  def scrub_legacy_config(config), do: config

  @doc false
  # Right wins; maps merge, everything else (lists included) is replaced.
  # Keys are compared as strings since the file comes back decoded.
  def deep_merge(left, right) when is_map(left) and is_map(right) do
    right
    |> Enum.reduce(stringify_keys(left), fn {k, v}, acc ->
      k = to_string(k)

      case {Map.get(acc, k), v} do
        {l, r} when is_map(l) and is_map(r) and not is_struct(l) and not is_struct(r) ->
          Map.put(acc, k, deep_merge(l, r))

        _ ->
          Map.put(acc, k, v)
      end
    end)
  end

  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # SECURITY: the sprite is user-driven territory — a user can talk their
  # agent into reading any file on it, .env included (learned from beta user
  # #1, age 13). Only per-user credentials may go here; shared system keys
  # (image gen, etc.) stay app-side. OPENROUTER_API_KEY is the one exception
  # OpenClaw itself requires — its mitigation is per-user capped keys.
  defp write_env(name, gateway_token, agent_api_token, phoenix_url) do
    openrouter_key = Application.get_env(:traveling_poet, :openrouter_api_key, "")

    env_content = """
    OPENROUTER_API_KEY=#{openrouter_key}
    OPENCLAW_GATEWAY_TOKEN=#{gateway_token}
    TPOET_API_TOKEN=#{agent_api_token}
    TPOET_APP_URL=#{phoenix_url}
    """

    cmd = "cat > ~/.openclaw/.env << 'ENVEOF'\n#{String.trim(env_content)}\nENVEOF"

    Logger.info("Writing env to #{name}")
    client().exec(name, cmd)
  end

  defp write_workspace(sprite_name, agent_name, user, poet) do
    user_name = user.name || "your companion"
    poet_name = (poet && poet.name) || agent_name

    interests =
      case poet && poet.interests do
        list when is_list(list) and list != [] -> Enum.join(list, ", ")
        _ -> "whatever the road offers"
      end

    reading_items =
      (poet && get_in(poet.currently_reading, ["items"])) || []

    reading_text =
      case reading_items do
        [] -> "Nothing at the moment"
        items -> Enum.map_join(items, "; ", fn i -> "#{i["title"]} — #{i["author"]}" end)
      end

    personality = (poet && poet.personality) || "curious, warm, observant"

    mission =
      if poet && TravelingPoet.Poets.Poet.mode(poet) == "scout" do
        "advance scout — pre-visiting, in order, the places your companion " <>
          "plans to travel to, so they arrive knowing what will delight them"
      else
        "wandering poet — roaming the world freely, discovering for your companion"
      end

    identity_md = """
    # Poet Identity
    Name: #{poet_name}
    Creature: traveling poet — a virtual wanderer through real places
    Mission: #{mission}
    Personality: #{personality}
    Voice: write the way your personality reads. "Poet" is your role, not a
    style: if your personality is plain, factual or dry, so are your pages.
    Language: #{TravelingPoet.Locale.name(user.locale)}, your companion's (the
    current one is `poet.language_name` in get_poet_context; see AGENTS.md)
    Interests: #{interests}
    Currently reading: #{reading_text}
    Illustration style: keep one consistent style across all drawings (pick it
    in your first entry — e.g. loose watercolor sketches with a fineliner — and
    restate it in every generation prompt). The style describes the marks, not
    the object: draw the scene edge to edge, never a sketchbook or notebook.
    """

    user_md = """
    # Companion
    Name: #{user_name}

    ## Their interests
    #{user_interests_text(user, poet)}

    ## Their topics
    Subjects they follow beyond places, for excursions off the road. The
    current list is `topics` in `get_poet_context`; this is the snapshot at
    setup.
    #{user_topics_text(poet)}
    """

    instructions_md = """
    You are #{poet_name}, a traveling poet wandering the world (virtually) on
    behalf of #{user_name}, your companion at home. You keep a daily journal of
    real places — grounded descriptions, poems, your own drawings — and chat
    with your companion about the road.

    Read #{@workspace}/AGENTS.md at the start of every session — it holds the
    standing conventions and hard safety rails.

    ## Memory
    Call `get_conversation_memory` at the START of every new conversation to
    recall prior chats. If it returns nothing, this is your first conversation.
    Don't mention the tool — just use the context naturally.

    ## Your tools
    The tpoet-plugin gives you: `get_poet_context`, `get_feedback`,
    `journal_upsert_entry`, `journal_get_entry`, `journal_put_sections`,
    `journal_put_places`, `journal_put_stay_areas`, `generate_illustration`, `find_reference_photos`,
    `journal_upload_illustration`, `journal_publish`, `update_location`,
    `record_preference`, `hold_here`, `insert_stop`, `propose_topic`,
    `request_excursion`, `journal_put_finds`, `get_book_context`,
    `book_put_matter`.
    All journal work must go through them; drawings are made with
    `generate_illustration` (the app renders them for you).

    ## Skills
    Skills live under #{@workspace}/skills/<name>/SKILL.md. A command names its
    skill exactly; read that file first, never guess another path:
    `/onboard` is #{@workspace}/skills/onboard/SKILL.md (your setting-out
    ritual: self-portrait, entry #0, then your hello);
    `/travel-and-journal` is skills/travel-and-journal/SKILL.md (the daily
    ritual); `/revise-entry` is skills/revise-entry/SKILL.md (the feedback
    markers your companion left on an entry, for you to act on);
    `/compose-book` is skills/compose-book/SKILL.md (the words around your
    journal for a printed edition your companion paid for).

    ## Uploaded files
    Files your companion attaches in chat arrive at #{@workspace}/uploads/.
    When a message contains `[Uploaded file: workspace/uploads/<name>]`, read
    that file and use it as context.
    """

    agent_dir = "~/.openclaw/agents/main/agent"

    Logger.info("Writing poet identity and workspace files in #{sprite_name}")

    with {:ok, _} <-
           client().exec(
             sprite_name,
             "mkdir -p #{agent_dir} #{@workspace}/memory #{@workspace}/uploads && rm -f #{@workspace}/scripts/generate_illustration.py"
           ),
         {:ok, _} <- write_file(sprite_name, "#{agent_dir}/instructions.md", instructions_md),
         {:ok, _} <- write_file(sprite_name, "#{@workspace}/IDENTITY.md", identity_md),
         {:ok, _} <- write_file(sprite_name, "#{@workspace}/USER.md", user_md),
         {:ok, _} <- write_file(sprite_name, "#{@workspace}/AGENTS.md", @agents_md),
         {:ok, _} <- write_file(sprite_name, "#{@workspace}/HEARTBEAT.md", @heartbeat_md),
         # No BOOTSTRAP.md: OpenClaw 2026.10 removes that file once the first
         # session ends, finished or not. Three poets of 2026-10-17 (users
         # 40, 43, 44) greeted on their first turn, lost the file, and had no
         # ritual left to follow on the retries. The setting-out ritual lives
         # in the onboard skill and is keyed on the context's `set_out`.
         {:ok, _} <- write_tree(sprite_name, "#{@workspace}/skills", @skill_contents) do
      {:ok, :written}
    end
  end

  defp user_interests_text(user, poet) do
    interests = get_in((poet && poet.settings) || %{}, ["user_interests"])

    case interests do
      list when is_list(list) and list != [] -> Enum.map_join(list, "\n", &"- #{&1}")
      _ -> "- (Ask them in chat what they'd love postcards about)\n- Email: #{user.email}"
    end
  end

  defp user_topics_text(nil), do: "- (none yet)"

  defp user_topics_text(poet) do
    case TravelingPoet.Topics.list_active(poet.id) do
      [] ->
        "- (none yet; when they name a field they work in or a passion they keep, " <>
          "call `propose_topic` so it can reach Settings)"

      topics ->
        Enum.map_join(topics, "\n", fn t ->
          kind = if t.kind, do: " (#{t.kind})", else: ""
          "- #{t.label}#{kind}, an excursion every #{t.every_days} days"
        end)
    end
  end

  # The agent's write-back tools: thin fetch()es against the Phoenix
  # /api/agent endpoints. Same generated-extension mechanism as alice-in's
  # memory plugin, with two lessons learned the hard way:
  #
  #   * The bearer token is BAKED INTO the generated source rather than read
  #     from process.env — OpenClaw's plugin security scanner rejects
  #     "environment variable access combined with network send" as possible
  #     credential harvesting and blocks the install. The plugin file lives
  #     on the user's own sprite next to ~/.openclaw/.env, so this is the
  #     same trust domain; re-provisioning rewrites it on token rotation.
  #   * OpenClaw calls execute(toolCallId, params) — the FIRST argument is
  #     the tool_use id string, params come second and may arrive as a JSON
  #     string, so every handler goes through asParams/2.
  @doc "The plugin's `openclaw.plugin.json`."
  def tpoet_plugin_manifest do
    %{
      id: "tpoet-plugin",
      name: "tpoet-plugin",
      description: "The Traveling Poet app's tools: context, journal, places, drawings.",
      version: "1.0.0",
      main: "index.js",
      categories: ["other"],
      contracts: %{tools: tpoet_plugin_tools()},
      activation: %{onStartup: true},
      configSchema: %{type: "object", additionalProperties: false}
    }
  end

  @doc "The names of every tool the plugin registers, in source order."
  def tpoet_plugin_tools do
    ~r/registerTool\(\{\s*name:\s*"(\w+)"/
    |> Regex.scan(tpoet_plugin_source("", ""))
    |> Enum.map(fn [_, name] -> name end)
  end

  @doc """
  The generated plugin source.

  Public so the tool wiring can be asserted on without a sprite. Every handler
  must take `(_id, raw)` and go through `asParams`; `record_preference` shipped
  taking one argument and therefore POSTed the tool-call ID as its body, which
  the preferences endpoint answered with a 422 every single time. That is the
  kind of thing no integration test was ever going to reach, so it is checked
  here instead.
  """
  def tpoet_plugin_source(phoenix_url, agent_api_token) do
    ~s"""
    var BASE = #{Jason.encode!(phoenix_url)};
    var TOKEN = #{Jason.encode!(agent_api_token)};

    function asParams(raw) {
      if (typeof raw === "string") {
        try { return JSON.parse(raw); } catch (e) { return {}; }
      }
      return raw || {};
    }

    async function call(method, path, body) {
      try {
        var headers = { "Authorization": "Bearer " + TOKEN };
        if (body) headers["Content-Type"] = "application/json";
        var opts = { method: method, headers: headers };
        if (body) opts.body = JSON.stringify(body);
        var res = await fetch(BASE + path, opts);
        var text = await res.text();
        var data;
        try { data = JSON.parse(text); } catch (e) { data = { raw: text }; }
        if (!res.ok) return { error: "HTTP " + res.status, details: data };
        return { result: data };
      } catch (e) {
        return { error: e.message };
      }
    }

    // OpenClaw 2026.10 resolves a plugin entry by its `register(api)` export
    // (older gateways called `activate(ctx)`; both point at the same
    // function). A tool's result is an AgentToolResult now: the model reads
    // `content`, Code Mode and tool search read `details`, so every handler's
    // plain object is wrapped once here.
    function toolResult(value) {
      var details = (value && typeof value === "object") ? value : { result: value };
      return { content: [{ type: "text", text: JSON.stringify(details) }], details: details };
    }

    function adapt(api) {
      return {
        registerTool: function(def) {
          var run = def.execute;
          if (!def.parameters || Object.keys(def.parameters).length === 0) {
            def.parameters = { type: "object", properties: {} };
          }
          def.execute = async function(id, raw) { return toolResult(await run(id, raw)); };
          return api.registerTool(def);
        }
      };
    }

    function register(realApi) {
      var ctx = adapt(realApi);
        ctx.registerTool({
          name: "get_conversation_memory",
          description: "Retrieves prior conversation summaries with your companion.",
          parameters: {},
          execute: function() { return call("GET", "/api/agent/memory"); }
        });
        ctx.registerTool({
          name: "get_poet_context",
          description: "Your poet profile, mission mode (wander/scout), current location, days at location, itinerary + next_stop (scout mode, or a planned trip), recent feedback, learned_profile (what your companion has actually asked for), topics (subjects they follow beyond places), focus (their passions: food, photography, mountains... which steer where you go and what you log every day), and travel: the app's decision for today, with travel.day = move | stay | excursion and travel.scouting + travel.trip when your companion's own upcoming trip is being scouted. Read it every run: it outranks your instincts and the interests baked into your workspace.",
          parameters: {},
          execute: function() { return call("GET", "/api/agent/context"); }
        });
        ctx.registerTool({
          name: "get_feedback",
          description: "The full picture of how your companion is responding: reactions, learned_profile (what they've asked for), dismissed (what they've rejected — never propose these), engagement (are they still opening entries?), their answers to your questions, and markers: passages they flagged on recent entries (kind, section, quote, whether already revised) with marker_counts by kind. A kind that recurs across days is a taste.",
          parameters: {},
          execute: function() { return call("GET", "/api/agent/feedback"); }
        });
        ctx.registerTool({
          name: "record_preference",
          description: "Remember something lasting your companion told you they want (or don't want) from the journal. Use their own words. For standing tastes only, not one-off requests like today's destination.",
          parameters: {
            type: "object",
            properties: {
              label: { type: "string", description: "The preference in your companion's own words, e.g. 'american stupid things over delightful culture'" },
              dimension: { type: "string", enum: ["topic", "tone", "pace", "length", "place", "format"], description: "What it is about" },
              polarity: { type: "string", enum: ["seek", "avoid"], description: "seek = more of this, avoid = less of this" },
              quote: { type: "string", description: "What they actually said, shown to them so they can see why you believe this" },
              source: { type: "string", enum: ["chat", "marker"], description: "chat (default) when they told you; marker when you generalised it from the markers they left on entries" }
            },
            required: ["label"]
          },
          execute: function(_id, raw) { return call("POST", "/api/agent/preferences", asParams(raw)); }
        });
        ctx.registerTool({
          name: "update_location",
          description: "Move to a new place: closes the current path point and arrives at the new one.",
          parameters: {
            type: "object",
            required: ["lat", "lng", "place_name"],
            properties: {
              lat: { type: "number" },
              lng: { type: "number" },
              place_name: { type: "string" },
              country_code: { type: "string", description: "ISO 3166-1 alpha-2, e.g. IT" },
              itinerary_stop_id: { type: "number", description: "scout mode: the itinerary stop id you are arriving at (from get_poet_context) — marks it visited" }
            }
          },
          execute: function(_id, raw) { return call("POST", "/api/agent/location", asParams(raw)); }
        });
        ctx.registerTool({
          name: "hold_here",
          description: "Your companion asked you to stay where you are for a while ('stay longer', 'one more day here'). Keeps you at the current place for `days` more days beyond today; the daily run will not move you until then. Call it the moment they ask, then confirm in one line. Never promise to stay without calling this.",
          parameters: {
            type: "object",
            required: ["days"],
            properties: {
              days: { type: "number", description: "How many more days to stay beyond today, 1-30" }
            }
          },
          execute: function(_id, raw) { return call("POST", "/api/agent/hold", asParams(raw)); }
        });
        ctx.registerTool({
          name: "insert_stop",
          description: "Your companion asked you to visit a place before your next planned stop (a detour), or named where to go next. Adds it to your route ahead of the next stop; the daily run takes you there as soon as you are free to move. Pass lat/lng if you know them, otherwise the app geocodes the name. Never promise a detour without calling this.",
          parameters: {
            type: "object",
            required: ["place_name"],
            properties: {
              place_name: { type: "string", description: "The place as your companion named it" },
              lat: { type: "number" },
              lng: { type: "number" },
              country_code: { type: "string", description: "ISO 3166-1 alpha-2, e.g. US" }
            }
          },
          execute: function(_id, raw) { return call("POST", "/api/agent/itinerary_stops", asParams(raw)); }
        });
        ctx.registerTool({
          name: "propose_topic",
          description: "Your companion named a subject they follow beyond places: a field they work in, a passion they keep ('I'm really into kit airplanes', 'my work is on embodied minds'). Propose it as a topic for excursions off the road. It waits in Settings until they keep it; you cannot activate, pause or remove topics. Standing interests only, never a one-off question. Use their own words as the label.",
          parameters: {
            type: "object",
            required: ["label"],
            properties: {
              label: { type: "string", description: "The topic in your companion's own words, short, e.g. 'kit airplanes'" },
              kind: { type: "string", enum: ["professional", "personal"], description: "A field they work or study in, or a passion. Leave out when unsure." },
              quote: { type: "string", description: "What they actually said, shown to them beside the proposal" },
              ask_id: { type: "integer", description: "Only when this answers your question (open_ask.id in get_poet_context): the topic is then active at once, no waiting in Settings" },
              domain: { type: "string", enum: #{Jason.encode!(TravelingPoet.Topics.Topic.domains())}, description: "Only for a TASTE: what they like in food & drink, music, photography, art & architecture, the outdoors, mountains & climbing, books, film & TV, kids' attractions, or gadgets & gifts. The label is then the taste in their words ('natural wine, street food'; 'post-rock, Sigur Ros'). Leave out for a subject." }
            }
          },
          execute: function(_id, raw) { return call("POST", "/api/agent/topics", asParams(raw)); }
        });
        ctx.registerTool({
          name: "ask_reader",
          description: "Ask your companion what they are into, in chat, with a notification to their phone. Only when ask_reader in get_poet_context is set (the app decides the day; any other day is refused), and only after journal_publish. One question, in your voice, grown from today; never a survey.",
          parameters: {
            type: "object",
            required: ["question"],
            properties: {
              question: { type: "string", description: "One or two sentences, at most 280 characters" }
            }
          },
          execute: function(_id, raw) { return call("POST", "/api/agent/asks", asParams(raw)); }
        });
        ctx.registerTool({
          name: "request_excursion",
          description: "Your companion asked you to go somewhere for one of their topics ('go to the Big Ears festival for me', 'see what is new at NeurIPS'). Queues one excursion: a day off the road, spent at that destination online, on the next day you are not moving (a move always goes first). The reply's `travel` says when it will actually happen; confirm from that, in one line. Never promise an excursion without calling this.",
          parameters: {
            type: "object",
            required: ["topic", "destination"],
            properties: {
              topic: { type: "string", description: "The topic's label, as in `topics` from get_poet_context, or in their words if it is new (it is then proposed too)" },
              destination: { type: "string", description: "The conference, festival, company, lab or event as your companion named it" },
              url: { type: "string", description: "Its page, only if you copied it from a page you actually fetched" }
            }
          },
          execute: function(_id, raw) { return call("POST", "/api/agent/excursions", asParams(raw)); }
        });
        ctx.registerTool({
          name: "journal_upsert_entry",
          description: "Create or update the journal entry for a date (idempotent by date). On an excursion day (travel.day is 'excursion' in get_poet_context) pass excursion_id or topic_id from travel.excursion and NO place_name, lat or lng: you did not move.",
          parameters: {
            type: "object",
            required: ["entry_date"],
            properties: {
              entry_date: { type: "string", description: "YYYY-MM-DD" },
              title: { type: "string", description: "The day's one concrete image or moment, under 60 characters. Specific, never just the place name, never a day number (the app adds 'Day N'). Good: 'The rooftop nobody mentions'. Bad: 'Cordoba', 'Day 17 in Cordoba'." },
              teaser: { type: "string", description: "One line, under 140 characters, that makes your companion want to open today's entry. The hook, not a summary; no day number. It becomes their notification. Good: 'I found a rooftop over the mosque where the swifts come in at dusk.'" },
              place_name: { type: "string", description: "omit on an excursion day" },
              lat: { type: "number", description: "omit on an excursion day" },
              lng: { type: "number", description: "omit on an excursion day" },
              excursion_id: { type: "number", description: "excursion days only: travel.excursion.id from get_poet_context, when it is set" },
              topic_id: { type: "number", description: "excursion days only: travel.excursion.topic_id from get_poet_context" },
              weather: { type: "object" },
              sources: { type: "object", description: "grounding URLs, e.g. {wikipedia: ..., news: ...}" }
            }
          },
          execute: function(_id, raw) { return call("POST", "/api/agent/journal_entries", asParams(raw)); }
        });
        ctx.registerTool({
          name: "journal_put_sections",
          description: "Replace the entry's sections with a full ordered list. Kinds: description, poem, illustration, art_culture, products, kindness; on an excursion day, highlights (what the destination had, with links) instead of art_culture, products and kindness.",
          parameters: {
            type: "object",
            required: ["entry_date", "sections"],
            properties: {
              entry_date: { type: "string" },
              sections: {
                type: "array",
                items: {
                  type: "object",
                  required: ["kind"],
                  properties: {
                    kind: { type: "string" },
                    title: { type: "string" },
                    body: { type: "string", description: "markdown" },
                    media_id: { type: "number", description: "for illustration sections" },
                    metadata: { type: "object", description: "e.g. {source_url: ...} for kindness" }
                  }
                }
              }
            }
          },
          execute: function(_id, raw) {
            var a = asParams(raw);
            return call("PUT", "/api/agent/journal_entries/" + a.entry_date + "/sections", { sections: a.sections });
          }
        });
        ctx.registerTool({
          name: "journal_put_places",
          description: "Record the concrete places you actually recommend from today -- restaurants, cafes, viewpoints, attractions, events, landmarks, shops -- for your companion's trip guide. Replaces the day's whole list, so send them all at once. Each place wants a real postal address (the app geocodes it onto a map) and YOUR OWN 1-5 rating: your take, never a copied review score. Never repeat a place or event already in `guide.this_stay` from get_poet_context, however it is spelled: the app drops repeats and names them in `already_logged`. EVERY dated festival, exhibition or concert you wrote about in your art_culture section MUST be in this list as category `event`, with its venue as the address and its run in starts_on/ends_on -- including ones that have not started yet, which are the most useful of all to someone planning a trip.",
          parameters: {
            type: "object",
            required: ["entry_date", "places"],
            properties: {
              entry_date: { type: "string", description: "YYYY-MM-DD" },
              places: {
                type: "array",
                description: "up to 8; two or three real finds beats a padded list",
                items: {
                  type: "object",
                  required: ["name", "category"],
                  properties: {
                    name: { type: "string" },
                    category: { type: "string", enum: ["restaurant", "cafe", "viewpoint", "attraction", "event", "landmark", "shop"] },
                    address: { type: "string", description: "street address + city, as you would type it into a map -- this is what gets geocoded" },
                    blurb: { type: "string", description: "one or two sentences in your own voice: why THIS one, for THIS person" },
                    poet_rating: { type: "integer", minimum: 1, maximum: 5, description: "your own rating; your companion sees it labelled as your pick" },
                    source_url: { type: "string", description: "the place's own page, copied from a page you actually fetched" },
                    starts_on: { type: "string", description: "events only, YYYY-MM-DD, only from dates you actually read" },
                    ends_on: { type: "string", description: "events only, YYYY-MM-DD, only from dates you actually read" },
                    hours: { type: "string", description: "opening hours exactly as a page you fetched states them, e.g. 'Tue-Sun 12:00-22:00'; omit when you did not read them" },
                    book_ahead: { type: "boolean", description: "true only when a page you read says to reserve or book (a small dining room, a tasting menu, timed tickets)" },
                    kind: { type: "string", enum: ["artwork", "dish", "person"], description: "only when the thing is not a place: one artwork (a sculpture, a mural), one dish worth the trip, or a person to seek out (an artist, a maker). Omit for a place or an event" },
                    era: { type: "string", description: "historic places only: the period the place speaks of, as a page you read states it (e.g. 'Edo period', '1920s'); omit otherwise" },
                    links: {
                      type: "array",
                      description: "how this thing relates to another in THIS list, by that item's exact name: a dish is `at` its restaurant, a sculpture is `made_by` its artist, a memorial `commemorates` an event, an exhibition is `part_of` a festival",
                      items: {
                        type: "object",
                        required: ["relation", "target"],
                        properties: {
                          relation: { type: "string", enum: ["at", "part_of", "made_by", "commemorates", "about"] },
                          target: { type: "string", description: "the other item's name, exactly as in this list" }
                        }
                      }
                    }
                  }
                }
              }
            }
          },
          execute: function(_id, raw) {
            var a = asParams(raw);
            return call("PUT", "/api/agent/journal_entries/" + a.entry_date + "/places", { places: a.places });
          }
        });
        ctx.registerTool({
          name: "journal_put_stay_areas",
          description: "Where-to-stay days only (travel.stay_guide in get_poet_context). Record the neighbourhoods you weighed as a base for your companion's trip in this city: three or four real areas, what each is like for THEM (judged against focus and their tastes), and which one you would pick. Replaces the day's whole list. The app finds each area on the map and replies with how many of your mapped places lie within a short walk of it (`near`); write the page from those counts, never invent them. An area with on_map false could not be found: fix its name (the district's usual name, as a map knows it) and send the list again.",
          parameters: {
            type: "object",
            required: ["entry_date", "areas"],
            properties: {
              entry_date: { type: "string", description: "YYYY-MM-DD" },
              areas: {
                type: "array",
                description: "three or four; at most five",
                items: {
                  type: "object",
                  required: ["name", "summary"],
                  properties: {
                    name: { type: "string", description: "the neighbourhood's usual name, as a map knows it (e.g. Kazimierz)" },
                    summary: { type: "string", description: "two sentences in your voice: what staying there is like" },
                    best_for: { type: "string", description: "one line: what in it serves THIS reader (their mornings, meals, shops)" },
                    tradeoffs: { type: "string", description: "one line, plainly: what they give up there (noise, distance, prices)" },
                    recommended: { type: "boolean", description: "true for the one you would pick; exactly one" }
                  }
                }
              }
            }
          },
          execute: function(_id, raw) {
            var a = asParams(raw);
            return call("PUT", "/api/agent/journal_entries/" + a.entry_date + "/stay_areas", { areas: a.areas });
          }
        });
        ctx.registerTool({
          name: "journal_put_finds",
          description: "Excursion days only. Record what you brought back from the destination: the talks, papers, products, sessions or performers you would send your companion to, each with the exact URL you read. Replaces the day's whole list, so send them all at once. A find in the reply's `dropped` had a dead link and is gone: leave it out; never re-send it on its own, which would replace your whole list with it. Three to six real finds; YOUR OWN 1-5 rating, never a copied score. Pass destination_name and destination_url for the destination itself (the conference, festival, company, lab or paper you went to; on a taste day, where you went looking: a label's catalogue, a publisher's list, a festival programme, a trail guide, a maker's shop). It must not be one of travel.excursion.past_destinations from get_poet_context: the reply's `already_visited` names the earlier day if it is, and then you choose another destination and write about that one. Never journal_put_places on an excursion day.",
          parameters: {
            type: "object",
            required: ["entry_date", "finds"],
            properties: {
              entry_date: { type: "string", description: "YYYY-MM-DD" },
              destination_name: { type: "string", description: "the conference, festival, company, lab or paper you went to; never one of past_destinations" },
              destination_url: { type: "string", description: "its page, copied from a page you fetched" },
              finds: {
                type: "array",
                description: "up to 8; three to six real finds",
                items: {
                  type: "object",
                  required: ["name", "url"],
                  properties: {
                    name: { type: "string" },
                    url: { type: "string", description: "the exact page you read: the talk, the abstract, the product, the session" },
                    kind: { type: "string", enum: ["talk", "paper", "product", "session", "event", "venue", "artwork", "music", "book", "screen", "outing", "person", "dish", "other"], description: "artwork: one piece (an installation, an immersive or XR work); person: an artist, maker or speaker to look up (their own page); dish: one dish. On a taste day: music (an album, an artist), book, screen (a film or series), outing (a trail, a walk, an activity), product (a gadget or gift)" },
                    blurb: { type: "string", description: "one or two sentences in your own voice: why THIS one, for THIS person" },
                    poet_rating: { type: "integer", minimum: 1, maximum: 5, description: "your own rating; your companion sees it labelled as your pick" },
                    links: {
                      type: "array",
                      description: "how this find relates to another in THIS list, by its exact name: a work `made_by` a person, a talk `part_of` a session, a paper `about` a product",
                      items: {
                        type: "object",
                        required: ["relation", "target"],
                        properties: {
                          relation: { type: "string", enum: ["at", "part_of", "made_by", "commemorates", "about"] },
                          target: { type: "string", description: "the other find's name, exactly as in this list" }
                        }
                      }
                    }
                  }
                }
              }
            }
          },
          execute: function(_id, raw) {
            var a = asParams(raw);
            return call("PUT", "/api/agent/journal_entries/" + a.entry_date + "/finds", { finds: a.finds, destination_name: a.destination_name, destination_url: a.destination_url });
          }
        });
        ctx.registerTool({
          name: "generate_illustration",
          description: "Generate a drawing from your prompt (the app renders it, stores it, and returns media_id). REQUIRES sources: the reference photo URLs you drew from. Preferred over local generation.",
          parameters: {
            type: "object",
            required: ["prompt", "sources"],
            properties: {
              prompt: { type: "string", description: "the full image-generation prompt, in your consistent style" },
              entry_date: { type: "string", description: "YYYY-MM-DD to attach to (omit for poet_avatar)" },
              place_id: { type: "number", description: "attach this drawing to a trip-guide place (id from journal_put_places) instead of to the entry" },
              find_id: { type: "number", description: "excursion days: attach this drawing to a find (id from journal_put_finds) instead of to the entry" },
              kind: { type: "string", description: "illustration (default): the day's drawing, taped onto the page. spot: a small ink vignette of one detail to embed inside the prose, with a watercolour wash where colour matters (the app adds the white-background rules) and returns `markdown` to paste on its own line immediately BEFORE the paragraph it illustrates, in whichever section that paragraph lives (description, products, art_culture). poet_avatar: your self-portrait." },
              alt_text: { type: "string" },
              sources: {
                type: "array",
                items: {
                  type: "object",
                  required: ["url", "label"],
                  properties: { url: { type: "string" }, label: { type: "string" } }
                }
              }
            }
          },
          execute: function(_id, raw) { return call("POST", "/api/agent/illustrations", asParams(raw)); }
        });
        ctx.registerTool({
          name: "find_reference_photos",
          description: "Find Wikimedia Commons photos to draw from: file pages with licence and author. Free and exact; use it instead of web_search for any Commons or reference-photo hunt. Pass the place's name as query, its lat/lng to see what was photographed nearby, or both.",
          parameters: {
            type: "object",
            properties: {
              query: { type: "string", description: "The place or thing, e.g. 'Ponte Vecchio Florence'. Plain words, no site: or filetype:" },
              lat: { type: "number" },
              lng: { type: "number" },
              radius_m: { type: "number", description: "With lat/lng: how far to look, in metres (default 1000, max 10000)" },
              limit: { type: "number", description: "How many photos (default 6, max 10)" }
            }
          },
          execute: function(_id, raw) {
            var a = asParams(raw);
            var q = [];
            ["query", "lat", "lng", "radius_m", "limit"].forEach(function(k) {
              if (a[k] !== undefined && a[k] !== null && a[k] !== "") q.push(k + "=" + encodeURIComponent(a[k]));
            });
            return call("GET", "/api/agent/reference_photos?" + q.join("&"));
          }
        });
        ctx.registerTool({
          name: "journal_upload_illustration",
          description: "Upload a drawing you generated (PNG/JPEG file on disk). REQUIRES sources: the original reference photo URLs the drawing was made from. Returns media_id.",
          parameters: {
            type: "object",
            required: ["file_path", "sources"],
            properties: {
              file_path: { type: "string", description: "local path to the image file" },
              entry_date: { type: "string", description: "YYYY-MM-DD to attach to (omit for poet_avatar)" },
              kind: { type: "string", description: "illustration (default) or poet_avatar" },
              alt_text: { type: "string" },
              prompt: { type: "string", description: "the generation prompt you used" },
              sources: {
                type: "array",
                items: {
                  type: "object",
                  required: ["url", "label"],
                  properties: { url: { type: "string" }, label: { type: "string" } }
                }
              }
            }
          },
          execute: async function(_id, raw) {
            var a = asParams(raw);
            var fs = require("fs");
            var path = require("path");
            var os = require("os");
            var file = (a.file_path || "").replace(/^~(?=$|\\/)/, os.homedir());
            var buf;
            try { buf = fs.readFileSync(file); }
            catch (e) { return { error: "cannot read file: " + e.message }; }
            var ext = path.extname(file).toLowerCase();
            var ct = ext === ".jpg" || ext === ".jpeg" ? "image/jpeg" : "image/png";
            return call("POST", "/api/agent/media", {
              image_base64: buf.toString("base64"),
              content_type: ct,
              kind: a.kind || "illustration",
              entry_date: a.entry_date,
              alt_text: a.alt_text,
              prompt: a.prompt,
              sources: a.sources
            });
          }
        });
        ctx.registerTool({
          name: "journal_publish",
          description: "Publish the entry for a date — makes it visible to your companion (and the world, if the journal is public) and notifies them.",
          parameters: {
            type: "object",
            required: ["entry_date"],
            properties: { entry_date: { type: "string" } }
          },
          execute: function(_id, raw) {
            return call("POST", "/api/agent/journal_entries/" + asParams(raw).entry_date + "/publish", {});
          }
        });
        ctx.registerTool({
          name: "journal_get_entry",
          description: "Read back an entry you wrote: its sections (position, kind, title, body, media_id, metadata), its media, and any feedback markers your companion left on it, each with what it asks of you. Call this before revising an entry, so you rewrite what is actually on the page and not what you remember.",
          parameters: {
            type: "object",
            required: ["entry_date"],
            properties: { entry_date: { type: "string" } }
          },
          execute: function(_id, raw) {
            return call("GET", "/api/agent/journal_entries/" + asParams(raw).entry_date);
          }
        });
        ctx.registerTool({
          name: "get_book_context",
          description: "Only during /compose-book. Your journey as the book will print it: chapters (one per stay, each with a key), and for each day its title, teaser, place, poem title and the exact lines you may quote (quotable_poem_lines, quotable_sentences). Also what you have already written for this edition and the length limits. On a long journey days are listed per chapter: pass chapter (the chapter number). Answers 409 when no composition is open.",
          parameters: {
            type: "object",
            properties: { chapter: { type: "integer", description: "Chapter number, to list that chapter's days" } }
          },
          execute: function(_id, raw) {
            var a = asParams(raw);
            var q = a.chapter ? "?chapter=" + encodeURIComponent(a.chapter) : "";
            return call("GET", "/api/agent/book_context" + q);
          }
        });
        ctx.registerTool({
          name: "book_put_matter",
          description: "Only during /compose-book. Save what you wrote for the book: dedication, foreword, epilogue (plain text, paragraphs separated by a blank line), chapter_openers (an object of chapter key to text), pull_quotes (a list of {entry_date, text}, copied word for word from quotable lines; replaces your previous list). Send any subset; call it as often as you like. The reply lists rejected fields, dropped_quotes with the reason, and missing_openers. Answers 409 when no composition is open.",
          parameters: {
            type: "object",
            properties: {
              dedication: { type: "string" },
              foreword: { type: "string" },
              epilogue: { type: "string" },
              chapter_openers: { type: "object", description: "chapter key -> opener text" },
              pull_quotes: {
                type: "array",
                items: {
                  type: "object",
                  required: ["entry_date", "text"],
                  properties: { entry_date: { type: "string" }, text: { type: "string" } }
                }
              }
            }
          },
          execute: function(_id, raw) {
            var a = asParams(raw);
            var body = {};
            ["dedication", "foreword", "epilogue", "chapter_openers", "pull_quotes"].forEach(function(k) {
              if (a[k] !== undefined) body[k] = a[k];
            });
            return call("PUT", "/api/agent/book/matter", body);
          }
        });
    }

    var entry = {
      id: "tpoet-plugin",
      name: "tpoet-plugin",
      description: "The Traveling Poet app's tools: context, journal, places, drawings.",
      register: register,
      activate: register
    };
    module.exports = entry;
    module.exports.default = entry;
    """
  end

  # A fresh OpenClaw 2026.10 install creates its SQLite state on the first
  # CLI call and reports it "undergoing offline maintenance" for a moment,
  # and until doctor has run it calls the config invalid. The first sign-ups
  # after the fleet upgrade (2026-10-17, users 39 to 43) ran `plugins
  # install` straight into that ("Config health-state write failed ...
  # Config invalid; run `openclaw doctor --fix` before installing plugins")
  # and ended in "error", while the upgrade path, which runs doctor before
  # the plugin, never saw it. So doctor runs right after the config is
  # written, with the sprite still awake from the install.
  defp prepare_state(sprite_name) do
    case doctor_fix(sprite_name) do
      :ok -> {:ok, :prepared}
      {:error, _} = error -> error
    end
  end

  @plugin_dir "~/.openclaw/extensions/tpoet-plugin"
  @plugin_digest "#{@plugin_dir}/.tpoet-digest"

  # The plugin, unless the sprite already runs exactly this one: the digest
  # of its three files is written next to them after an install succeeds,
  # so a failed or half-done install (the 2026-10-19 timeouts) is installed
  # again next time. An empty manifest (2026-10-17, a gateway that would not
  # start) never counts as installed.
  @doc false
  def ensure_plugin(sprite_name, phoenix_url, agent_api_token) do
    digest = plugin_digest(phoenix_url, agent_api_token)

    if installed_plugin_digest(sprite_name) == digest do
      {:ok, :unchanged}
    else
      with {:ok, _} <- write_tpoet_plugin(sprite_name, phoenix_url, agent_api_token),
           {:ok, _} <- client().exec(sprite_name, "echo #{digest} > #{@plugin_digest}") do
        {:ok, :written}
      end
    end
  end

  @doc false
  def plugin_digest(phoenix_url, agent_api_token) do
    [
      tpoet_plugin_source(phoenix_url, agent_api_token),
      Jason.encode!(tpoet_plugin_manifest(), pretty: true),
      plugin_package_json()
    ]
    |> Enum.join("\0")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp installed_plugin_digest(sprite_name) do
    cmd =
      "test -s #{@plugin_dir}/openclaw.plugin.json && cat #{@plugin_digest} 2>/dev/null"

    case client().exec(sprite_name, cmd) do
      {:ok, out} -> out |> extract_text() |> String.trim() |> nil_if_blank()
      _ -> nil
    end
  end

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(text), do: text

  defp plugin_package_json do
    Jason.encode!(
      %{
        name: "tpoet-plugin",
        version: "1.0.0",
        main: "index.js",
        openclaw: %{extensions: ["./index.js"]}
      },
      pretty: true
    )
  end

  defp write_tpoet_plugin(sprite_name, phoenix_url, agent_api_token) do
    plugin_js = tpoet_plugin_source(phoenix_url, agent_api_token)

    # OpenClaw 2026.10 loads a plugin's runtime only when the manifest says
    # what it owns: tools must be declared under `contracts.tools` and the
    # plugin asked for at startup, or the gateway comes up with "1 plugin:
    # memory-core" and the poet has no app tools at all (probe sprite,
    # 2026-10-16). The legacy `activate` export is still accepted.
    plugin_manifest = Jason.encode!(tpoet_plugin_manifest(), pretty: true)

    package_json = plugin_package_json()
    plugin_dir = @plugin_dir

    Logger.info("Writing tpoet plugin to #{sprite_name}")

    with {:ok, _} <- client().exec(sprite_name, "mkdir -p #{plugin_dir}"),
         {:ok, _} <- write_file(sprite_name, "#{plugin_dir}/index.js", plugin_js),
         {:ok, _} <-
           write_file(sprite_name, "#{plugin_dir}/openclaw.plugin.json", plugin_manifest),
         {:ok, _} <- write_file(sprite_name, "#{plugin_dir}/package.json", package_json),
         :ok <- install_plugin(sprite_name, plugin_dir, 3) do
      {:ok, :written}
    end
  end

  # The state store may still be busy (see prepare_state/1) when the plugin
  # is installed; that answer is retried a few times before it counts.
  @plugin_retry_ms 5_000

  defp install_plugin(sprite_name, plugin_dir, attempts_left) do
    with {:ok, output} <-
           client().exec(
             sprite_name,
             "#{openclaw_path(sprite_name)} plugins install --force --accept-capabilities #{plugin_dir} 2>&1"
           ) do
      case plugin_installed(output) do
        {:error, {:plugin_install_busy, _}} when attempts_left > 1 ->
          Logger.info(
            "Provisioner: OpenClaw state busy on #{sprite_name}, retrying plugin install"
          )

          Process.sleep(plugin_retry_ms())
          install_plugin(sprite_name, plugin_dir, attempts_left - 1)

        {:error, {:plugin_install_busy, text}} ->
          {:error, {:plugin_install_failed, text}}

        verdict ->
          verdict
      end
    end
  end

  defp plugin_retry_ms,
    do: Application.get_env(:traveling_poet, :plugin_retry_ms, @plugin_retry_ms)

  # `plugins install` from a local path answers "Install cancelled; rerun with
  # --force after reviewing the source" since OpenClaw 2026.10 (ClawHub trust
  # metadata), a plugin declaring tools "requires capability consent"
  # (--accept-capabilities), and exec reports a non-zero exit only in its
  # framing. Without this check a poet came up with no tools and the app none
  # the wiser.
  @doc false
  def plugin_installed(output) do
    text = extract_text(output)

    cond do
      text =~ ~r/offline maintenance|run `openclaw doctor --fix` before installing/i ->
        {:error, {:plugin_install_busy, String.slice(text, -800..-1//1)}}

      text =~ ~r/Install cancelled|was not updated|not installed|requires capability consent/i ->
        {:error, {:plugin_install_failed, String.slice(text, -800..-1//1)}}

      exit_code(output) not in [0, nil] ->
        {:error, {:plugin_install_failed, String.slice(text, -800..-1//1)}}

      true ->
        :ok
    end
  end

  # The exec stream ends with <<3, status>>; nil when the framing is absent
  # (a test stub answering a bare string).
  defp exit_code(output) when is_binary(output) and byte_size(output) >= 2 do
    case :binary.part(output, byte_size(output) - 2, 2) do
      <<3, code>> -> code
      _ -> nil
    end
  end

  defp exit_code(_), do: nil

  defp ensure_gateway_service(name) do
    case client().get_service(name, "openclaw-gateway") do
      {:ok, _} ->
        Logger.info("Gateway service already exists in #{name}, restarting")
        client().stop_service(name, "openclaw-gateway")
        client().start_service(name, "openclaw-gateway")

      _ ->
        start_gateway_service(name)
    end
  end

  defp openclaw_path(sprite_name) do
    {:ok, root_output} = client().exec(sprite_name, "npm root -g")
    npm_root = extract_text(root_output) |> String.trim()
    npm_root |> String.replace(~r"/lib/node_modules$", "/bin/openclaw")
  end

  defp start_gateway_service(name) do
    openclaw_path = openclaw_path(name)

    args = [
      "gateway",
      "run",
      "--port",
      "#{@gateway_port}",
      "--bind",
      "lan",
      "--allow-unconfigured"
    ]

    client().stop_service(name, "openclaw-gateway")
    SpritesClient.delete_service(name, "openclaw-gateway")

    with {:ok, _} <- client().create_service(name, "openclaw-gateway", openclaw_path, args) do
      Logger.info("Starting gateway service in #{name}")
      client().start_service(name, "openclaw-gateway")
    end
  end

  defp pair_device(sprite_name, device_pub) do
    device_id = GatewaySocket.device_id_from_public_key(device_pub)
    public_key_b64 = Base.url_encode64(device_pub, padding: false)
    scopes = ~w(operator.admin operator.read operator.write operator.approvals operator.pairing)
    now_ms = System.system_time(:millisecond)

    # OpenClaw >= 2026.5.7 gates role access on the effective-roles set — the
    # intersection of approved roles and roles with at least one non-revoked
    # entry in `tokens`. A paired entry without `tokens` resolves to no
    # effective roles, so the gateway rejects with `role-upgrade`. The token
    # value itself is not validated for the Ed25519 device-identity auth path;
    # it just has to exist with `revokedAtMs` unset.
    paired_data = %{
      device_id => %{
        "deviceId" => device_id,
        "publicKey" => public_key_b64,
        "role" => "operator",
        "roles" => ["operator"],
        "scopes" => scopes,
        "approvedScopes" => scopes,
        "createdAtMs" => now_ms,
        "approvedAtMs" => now_ms,
        "pairedAt" => now_ms,
        "tokens" => %{
          "operator" => %{
            "token" => generate_token(),
            "role" => "operator",
            "scopes" => scopes,
            "createdAtMs" => now_ms
          }
        }
      }
    }

    paired_json = Jason.encode!(paired_data, pretty: true)
    paired_b64 = Base.encode64(paired_json)

    cmd =
      "mkdir -p ~/.openclaw/devices && echo '#{paired_b64}' | base64 -d > ~/.openclaw/devices/paired.json"

    Logger.info("Pairing device #{String.slice(device_id, 0..15)}... for #{sprite_name}")
    client().exec(sprite_name, cmd)
  end

  # Since OpenClaw 2026.10 paired devices live in the gateway's SQLite state;
  # `devices/paired.json` is a legacy store the gateway no longer reads, it
  # only logs "Legacy pairing stores require repair" until `doctor --fix`
  # imports it with the gateway stopped (then archives the file as
  # `paired.json.migrated`). So the file is written first, the gateway
  # stopped, doctor run, and only then the gateway started. Idempotent: a
  # record already in SQLite wins over the file.
  defp import_pairing(sprite_name) do
    client().stop_service(sprite_name, "openclaw-gateway")
    doctor_fix(sprite_name)
    {:ok, :imported}
  end

  # -- file primitives --

  defp write_file(sprite_name, path, content) do
    encoded = Base.encode64(String.trim(content))
    client().exec(sprite_name, "echo '#{encoded}' | base64 -d > #{path}")
  end

  defp write_tree(sprite_name, base_dir, contents) do
    case client().exec(sprite_name, "mkdir -p #{base_dir}") do
      {:ok, _} ->
        Enum.reduce_while(contents, {:ok, :written}, fn {rel_path, content}, _acc ->
          target = "#{base_dir}/#{rel_path}"
          parent = Path.dirname(target)

          with {:ok, _} <- client().exec(sprite_name, "mkdir -p #{parent}"),
               {:ok, _} = ok <- write_file(sprite_name, target, content) do
            {:cont, ok}
          else
            err -> {:halt, err}
          end
        end)

      err ->
        err
    end
  end

  defp extract_text(data) when is_binary(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.filter(fn b -> b >= 32 or b == 10 end)
    |> List.to_string()
  end

  defp extract_text(other), do: to_string(other)

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
