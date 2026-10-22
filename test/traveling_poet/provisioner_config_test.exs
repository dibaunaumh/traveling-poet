defmodule TravelingPoet.ProvisionerConfigTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.{AgentSession, Provisioner}

  test "openclaw config disables the heartbeat and pins the model" do
    config = Provisioner.openclaw_config("gw-token", "https://poet.travel", "vendor/model-x")

    assert config.agents.defaults.heartbeat.every == "0m"
    assert config.agents.defaults.model == "openrouter/vendor/model-x"
    assert config.gateway.auth.token == "gw-token"
  end

  # The fleet model has no image endpoint on OpenRouter. Declared with image
  # input, OpenClaw 2026.10 sends image parts and OpenRouter answers 404
  # "No endpoints found that support image input" for every turn after,
  # which took one poet's chat down for a day.
  test "the fleet model is declared text only so image parts are dropped, not sent" do
    config = Provisioner.openclaw_config("gw-token", "https://poet.travel", "vendor/model-x")
    [model] = config.models.providers["openrouter"].models

    assert model.id == "vendor/model-x"
    assert model.input == ["text"]
  end

  # A 2026.4.9 gateway wrote meta.lastTouchedAt; 2026.10 rejects the whole
  # file over it ("meta: Unrecognized key"), and the merge that protects the
  # gateway's own keys would carry it along forever.
  test "the config writer drops keys the pinned release refuses, keeping the rest of meta" do
    on_sprite = %{
      "meta" => %{
        "lastTouchedAt" => "2026-10-15T02:07:30.673Z",
        "lastTouchedVersion" => "2026.4.9"
      },
      "gateway" => %{"auth" => %{"token" => "old"}}
    }

    ours = %{"gateway" => %{"auth" => %{"token" => "new"}}}
    merged = on_sprite |> Provisioner.deep_merge(ours) |> Provisioner.scrub_legacy_config()

    assert merged["meta"] == %{"lastTouchedVersion" => "2026.4.9"}
    assert merged["gateway"]["auth"]["token"] == "new"
    assert Provisioner.scrub_legacy_config(%{"gateway" => %{}}) == %{"gateway" => %{}}
  end

  # Every connection reaches the gateway through the sprites.app proxy with
  # X-Forwarded-For; OpenClaw 2026.10 answers 403 proxy_attribution_required
  # unless that proxy is trusted. The port in the config is what OpenClaw's
  # own CLI (doctor, plugins, devices) uses to find the running gateway.
  test "the sprite proxy is trusted and the CLI can find the gateway" do
    config = Provisioner.openclaw_config("gw-token", "https://poet.travel", "vendor/model-x")

    assert config.gateway.trustedProxies == ["10.0.0.0/8"]
    assert config.gateway.port == 8080
    assert config.gateway.bind == "lan"
  end

  # With tool search on (the 2026.10 default) the fleet model looped hunting
  # for journal_put_places; the workshop review spends model turns of its own.
  test "tools are offered as direct schemas and the skill workshop stays off" do
    config = Provisioner.openclaw_config("gw-token", "https://poet.travel", "vendor/model-x")

    assert config.tools.toolSearch == false
    assert config.skills.workshop.autonomous.mode == "off"
  end

  # 2026-10-17 to 10-22: the nightly dreaming sweep's reports reached 22
  # readers' chats.
  test "memory-core dreaming is off" do
    config = Provisioner.openclaw_config("gw-token", "https://poet.travel", "vendor/model-x")

    assert config.plugins.entries["memory-core"].config.dreaming.enabled == false
  end

  # Without `contracts.tools` and startup activation the 2026.10 gateway never
  # loads the plugin ("1 plugin: memory-core") and the poet has no app tools.
  test "the plugin manifest declares every registered tool and loads at startup" do
    manifest = Provisioner.tpoet_plugin_manifest()

    assert manifest.id == "tpoet-plugin"
    assert manifest.activation.onStartup == true
    assert manifest.contracts.tools == Provisioner.tpoet_plugin_tools()
    assert length(manifest.contracts.tools) >= 20
    assert "get_poet_context" in manifest.contracts.tools
    assert "journal_put_places" in manifest.contracts.tools
  end

  test "web_search is pinned to Sonar over OpenRouter, with the model from config" do
    config = Provisioner.openclaw_config("gw-token", "https://poet.travel", "vendor/model-x")

    assert config.tools.web.search.provider == "perplexity"
    web_search = config.plugins.entries["perplexity"].config.webSearch
    assert web_search.model == "test/search-model"
    assert web_search.baseUrl == "https://openrouter.ai/api/v1"
    # the key comes from ~/.openclaw/.env, never baked into the config file
    refute Map.has_key?(web_search, :apiKey)
    assert "perplexity" in config.plugins.allow
    assert config.plugins.entries["perplexity"].enabled
  end

  test "heartbeat acknowledgements are not treated as a poet's reply" do
    assert AgentSession.housekeeping_reply?("HEARTBEAT_OK")
    assert AgentSession.housekeeping_reply?("NO_REPLY")
    refute AgentSession.housekeeping_reply?("")
    refute AgentSession.housekeeping_reply?(nil)
    refute AgentSession.housekeeping_reply?("I added the link to Liberty Public Market.")
  end

  # Real replies from the fleet, 2026-10-17 to 10-22.
  test "a report on a dreaming sweep is not a poet's reply" do
    for report <- [
          "This is a system-level memory consolidation (\"dreaming\") cron job: it handles " <>
            "promoting short-term memory patterns to long-term storage.",
          "This is an internal OpenClaw memory core system cron " <>
            "(`__openclaw_memory_core_short_term_promotion_dream__`). No work to perform.",
          "Memory dreaming run complete. Consolidated the strongest uncaptured signal."
        ] do
      assert AgentSession.housekeeping_reply?(report), report
    end
  end

  test "a page or postcard that mentions a dream is still a reply" do
    for prose <- [
          "**Day 5**: The palace that dreams in colour. A fever dream of yellow and red.",
          "Venice Beach is Abbot Kinney's bonkers 1905 dream: canals, a gondola, a Ship Cafe.",
          "Built out of a 1988 dream of a four-tower City of Air that the bubble economy cut."
        ] do
      refute AgentSession.housekeeping_reply?(prose), prose
    end
  end
end
