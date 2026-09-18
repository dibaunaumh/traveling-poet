defmodule TravelingPoet.ProvisionerConfigTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.{AgentSession, Provisioner}

  test "openclaw config disables the heartbeat and pins the model" do
    config = Provisioner.openclaw_config("gw-token", "https://poet.travel", "vendor/model-x")

    assert config.agents.defaults.heartbeat.every == "0m"
    assert config.agents.defaults.model == "openrouter/vendor/model-x"
    assert config.gateway.auth.token == "gw-token"
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
