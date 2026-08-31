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

  @bootstrap_path "priv/data/BOOTSTRAP.md"
  @external_resource @bootstrap_path
  @bootstrap_md File.read!(@bootstrap_path)

  @heartbeat_path "priv/data/HEARTBEAT.md"
  @external_resource @heartbeat_path
  @heartbeat_md File.read!(@heartbeat_path)

  @skill_names ~w(travel-and-journal discover poem chat-companion onboard)
  @skill_contents (for skill <- @skill_names, into: %{} do
                     path = "priv/data/skills/#{skill}/SKILL.md"
                     Module.put_attribute(__MODULE__, :external_resource, path)
                     {"#{skill}/SKILL.md", File.read!(path)}
                   end)

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

    with {:ok, _} <- create_sprite(sprite_name),
         {:ok, _} <- make_public(sprite_name),
         {:ok, _} <- install_openclaw(sprite_name, openclaw_version),
         {:ok, _} <- write_config(sprite_name, gateway_token, phoenix_url, poet_model(poet)),
         {:ok, _} <- write_env(sprite_name, gateway_token, agent_api_token, phoenix_url),
         {:ok, _} <- write_workspace(sprite_name, agent_name, user, poet),
         {:ok, _} <- write_tpoet_plugin(sprite_name, phoenix_url, agent_api_token),
         {:ok, _} <- ensure_gateway_service(sprite_name),
         {:ok, _} <- pair_device(sprite_name, device_pub),
         {:ok, sprite_url} <- SpritesClient.get_sprite_url(sprite_name) do
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
  Re-seed workspace files (skills/AGENTS/scripts) AND the tool plugin on an
  existing sprite.

  The plugin used to be written only by `do_provision_user/2`, so a poet
  provisioned last week could never gain a new tool — the app would ship an
  endpoint no agent knew how to call. Rewriting it here makes this the light
  way to roll changes across the fleet: full re-provisioning re-runs npm
  checks, device pairing and service teardown, which is a lot of risk to take
  on eight live sprites just to deliver a skill edit.

  Note skills are compile-time embedded (`@skill_contents`), so editing a
  SKILL.md needs `mix compile --force` before this will carry the new text.
  """
  def upgrade_workspace(user) do
    sprite_name = user.sprite_name || default_sprite_name(user.id)
    poet = TravelingPoet.Poets.get_poet_by_user(user.id)
    phoenix_url = Application.get_env(:traveling_poet, :phoenix_url, "http://localhost:4000")

    with {:ok, _} <- write_workspace(sprite_name, user.agent_name || "poet", user, poet),
         {:ok, _} <- write_tpoet_plugin(sprite_name, phoenix_url, user.agent_api_token),
         {:ok, _} <- SpritesClient.stop_service(sprite_name, "openclaw-gateway"),
         {:ok, _} <- ensure_gateway_service(sprite_name) do
      {:ok, sprite_name}
    end
  end

  @doc """
  Rolls workspace + plugin changes across every provisioned poet, staggered so
  the fleet doesn't hammer the sprites API. Returns `{sprite_or_user, result}`
  per user.
  """
  def upgrade_fleet(opts \\ []) do
    stagger_ms = Keyword.get(opts, :stagger_ms, 3_000)

    TravelingPoet.Accounts.list_provisioned_users()
    |> Enum.map(fn user ->
      result = upgrade_workspace(user)
      Process.sleep(stagger_ms)
      {user.email, elem_or_error(result)}
    end)
  end

  defp elem_or_error({:ok, name}), do: {:ok, name}
  defp elem_or_error(other), do: other

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

  defp install_openclaw(name, openclaw_version) do
    npm_version = resolve_openclaw_npm_version(openclaw_version)

    case SpritesClient.exec(name, "command -v openclaw") do
      {:ok, output} ->
        if extract_text(output) |> String.contains?("openclaw") do
          Logger.info("OpenClaw already installed in #{name}, skipping")
          {:ok, :already_installed}
        else
          do_install_openclaw(name, npm_version)
        end

      _ ->
        do_install_openclaw(name, npm_version)
    end
  end

  defp resolve_openclaw_npm_version("stable") do
    Application.get_env(:traveling_poet, :openclaw_stable_version, "2026.4.9")
  end

  defp resolve_openclaw_npm_version(_), do: "latest"

  defp do_install_openclaw(name, npm_version) do
    Logger.info("Installing OpenClaw #{npm_version} in #{name}")

    SpritesClient.exec(
      name,
      "npm install -g openclaw@#{npm_version} && mkdir -p #{@workspace}/memory"
    )
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

  defp write_config(name, gateway_token, phoenix_url, model) do
    config = %{
      gateway: %{
        controlUi: %{allowedOrigins: ["*", phoenix_url]},
        http: %{endpoints: %{responses: %{enabled: true}}},
        auth: %{token: gateway_token}
      },
      agents: %{defaults: %{model: "openrouter/#{model}"}},
      plugins: %{allow: ["tpoet-plugin"]},
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
                input: ["text", "image"],
                contextWindow:
                  Application.get_env(:traveling_poet, :openrouter_context_window, 200_000),
                maxTokens: Application.get_env(:traveling_poet, :openrouter_max_tokens, 32_768)
              }
            ]
          }
        }
      }
    }

    config_json = Jason.encode!(config, pretty: true)

    cmd =
      "mkdir -p ~/.openclaw && cat > ~/.openclaw/openclaw.json << 'CONFIGEOF'\n#{config_json}\nCONFIGEOF"

    Logger.info("Writing config to #{name}")
    SpritesClient.exec(name, cmd)
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
    SpritesClient.exec(name, cmd)
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
    Interests: #{interests}
    Currently reading: #{reading_text}
    Illustration style: keep one consistent style across all drawings (pick it
    in your first entry — e.g. loose watercolor travel-journal sketches — and
    restate it in every generation prompt).
    """

    user_md = """
    # Companion
    Name: #{user_name}

    ## Their interests
    #{user_interests_text(user, poet)}
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
    `journal_upsert_entry`, `journal_put_sections`, `generate_illustration`,
    `journal_upload_illustration`, `journal_publish`, `update_location`.
    All journal work must go through them; drawings are made with
    `generate_illustration` (the app renders them for you).

    ## Skills
    Skills live under #{@workspace}/skills/ — scan the SKILL.md descriptions
    and load the matching one before acting. `/travel-and-journal` triggers the
    daily ritual; `/onboard` triggers your first-session bootstrap.

    ## Uploaded files
    Files your companion attaches in chat arrive at #{@workspace}/uploads/.
    When a message contains `[Uploaded file: workspace/uploads/<name>]`, read
    that file and use it as context.
    """

    agent_dir = "~/.openclaw/agents/main/agent"

    Logger.info("Writing poet identity and workspace files in #{sprite_name}")

    with {:ok, _} <-
           SpritesClient.exec(
             sprite_name,
             "mkdir -p #{agent_dir} #{@workspace}/memory #{@workspace}/uploads && rm -f #{@workspace}/scripts/generate_illustration.py"
           ),
         {:ok, _} <- write_file(sprite_name, "#{agent_dir}/instructions.md", instructions_md),
         {:ok, _} <- write_file(sprite_name, "#{@workspace}/IDENTITY.md", identity_md),
         {:ok, _} <- write_file(sprite_name, "#{@workspace}/USER.md", user_md),
         {:ok, _} <- write_file(sprite_name, "#{@workspace}/AGENTS.md", @agents_md),
         {:ok, _} <- write_file(sprite_name, "#{@workspace}/HEARTBEAT.md", @heartbeat_md),
         # never clobber a completed bootstrap on re-provision
         {:ok, _} <-
           write_file_if_absent(sprite_name, "#{@workspace}/BOOTSTRAP.md", @bootstrap_md),
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
  defp write_tpoet_plugin(sprite_name, phoenix_url, agent_api_token) do
    plugin_js = ~s"""
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

    module.exports = {
      activate: function(ctx) {
        ctx.registerTool({
          name: "get_conversation_memory",
          description: "Retrieves prior conversation summaries with your companion.",
          parameters: {},
          execute: function() { return call("GET", "/api/agent/memory"); }
        });
        ctx.registerTool({
          name: "get_poet_context",
          description: "Your poet profile, mission mode (wander/scout), current location, days at location, itinerary + next_stop (scout mode), recent feedback, and learned_profile — what your companion has actually asked for. Read it every run: it outranks your instincts and the interests baked into your workspace.",
          parameters: {},
          execute: function() { return call("GET", "/api/agent/context"); }
        });
        ctx.registerTool({
          name: "get_feedback",
          description: "The full picture of how your companion is responding: reactions, learned_profile (what they've asked for), dismissed (what they've rejected — never propose these), engagement (are they still opening entries?), and their answers to your questions.",
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
              quote: { type: "string", description: "What they actually said, shown to them so they can see why you believe this" }
            },
            required: ["label"]
          },
          execute: function(params) { return call("POST", "/api/agent/preferences", params); }
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
          name: "journal_upsert_entry",
          description: "Create or update the journal entry for a date (idempotent by date).",
          parameters: {
            type: "object",
            required: ["entry_date"],
            properties: {
              entry_date: { type: "string", description: "YYYY-MM-DD" },
              title: { type: "string" },
              place_name: { type: "string" },
              lat: { type: "number" },
              lng: { type: "number" },
              weather: { type: "object" },
              sources: { type: "object", description: "grounding URLs, e.g. {wikipedia: ..., news: ...}" }
            }
          },
          execute: function(_id, raw) { return call("POST", "/api/agent/journal_entries", asParams(raw)); }
        });
        ctx.registerTool({
          name: "journal_put_sections",
          description: "Replace the entry's sections with a full ordered list. Kinds: description, poem, illustration, art_culture, products, kindness.",
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
          name: "generate_illustration",
          description: "Generate a drawing from your prompt (the app renders it, stores it, and returns media_id). REQUIRES sources: the reference photo URLs you drew from. Preferred over local generation.",
          parameters: {
            type: "object",
            required: ["prompt", "sources"],
            properties: {
              prompt: { type: "string", description: "the full image-generation prompt, in your consistent style" },
              entry_date: { type: "string", description: "YYYY-MM-DD to attach to (omit for poet_avatar)" },
              kind: { type: "string", description: "illustration (default) or poet_avatar" },
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
      }
    };
    """

    plugin_manifest =
      Jason.encode!(
        %{
          id: "tpoet-plugin",
          name: "tpoet-plugin",
          version: "1.0.0",
          main: "index.js",
          configSchema: %{}
        },
        pretty: true
      )

    package_json =
      Jason.encode!(
        %{
          name: "tpoet-plugin",
          version: "1.0.0",
          main: "index.js",
          openclaw: %{extensions: ["./index.js"]}
        },
        pretty: true
      )

    plugin_dir = "~/.openclaw/extensions/tpoet-plugin"

    Logger.info("Writing tpoet plugin to #{sprite_name}")

    with {:ok, _} <- SpritesClient.exec(sprite_name, "mkdir -p #{plugin_dir}"),
         {:ok, _} <- write_file(sprite_name, "#{plugin_dir}/index.js", plugin_js),
         {:ok, _} <-
           write_file(sprite_name, "#{plugin_dir}/openclaw.plugin.json", plugin_manifest),
         {:ok, _} <- write_file(sprite_name, "#{plugin_dir}/package.json", package_json),
         {:ok, _} <-
           SpritesClient.exec(
             sprite_name,
             "#{openclaw_path(sprite_name)} plugins install #{plugin_dir} 2>&1"
           ) do
      {:ok, :written}
    end
  end

  defp ensure_gateway_service(name) do
    case SpritesClient.get_service(name, "openclaw-gateway") do
      {:ok, _} ->
        Logger.info("Gateway service already exists in #{name}, restarting")
        SpritesClient.stop_service(name, "openclaw-gateway")
        SpritesClient.start_service(name, "openclaw-gateway")

      _ ->
        start_gateway_service(name)
    end
  end

  defp openclaw_path(sprite_name) do
    {:ok, root_output} = SpritesClient.exec(sprite_name, "npm root -g")
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

    SpritesClient.stop_service(name, "openclaw-gateway")
    SpritesClient.delete_service(name, "openclaw-gateway")

    with {:ok, _} <- SpritesClient.create_service(name, "openclaw-gateway", openclaw_path, args) do
      Logger.info("Starting gateway service in #{name}")
      SpritesClient.start_service(name, "openclaw-gateway")
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
    SpritesClient.exec(sprite_name, cmd)
  end

  # -- file primitives --

  defp write_file(sprite_name, path, content) do
    encoded = Base.encode64(String.trim(content))
    SpritesClient.exec(sprite_name, "echo '#{encoded}' | base64 -d > #{path}")
  end

  defp write_file_if_absent(sprite_name, path, content) do
    encoded = Base.encode64(String.trim(content))

    SpritesClient.exec(
      sprite_name,
      "test -f #{path} || test -f #{String.replace(path, ".md", ".completed.md")} || echo '#{encoded}' | base64 -d > #{path}"
    )
  end

  defp write_tree(sprite_name, base_dir, contents) do
    case SpritesClient.exec(sprite_name, "mkdir -p #{base_dir}") do
      {:ok, _} ->
        Enum.reduce_while(contents, {:ok, :written}, fn {rel_path, content}, _acc ->
          target = "#{base_dir}/#{rel_path}"
          parent = Path.dirname(target)

          with {:ok, _} <- SpritesClient.exec(sprite_name, "mkdir -p #{parent}"),
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
