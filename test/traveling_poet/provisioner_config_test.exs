defmodule TravelingPoet.ProvisionerConfigTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.{AgentSession, Provisioner}

  test "openclaw config disables the heartbeat and pins the model" do
    config = Provisioner.openclaw_config("gw-token", "https://poet.travel", "vendor/model-x")

    assert config.agents.defaults.heartbeat.every == "0m"
    assert config.agents.defaults.model == "openrouter/vendor/model-x"
    assert config.gateway.auth.token == "gw-token"
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
    assert AgentSession.heartbeat_reply?("HEARTBEAT_OK")
    assert AgentSession.heartbeat_reply?("NO_REPLY")
    refute AgentSession.heartbeat_reply?("")
    refute AgentSession.heartbeat_reply?("I added the link to Liberty Public Market.")
  end
end
