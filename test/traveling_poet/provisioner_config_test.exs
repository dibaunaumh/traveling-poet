defmodule TravelingPoet.ProvisionerConfigTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.{AgentSession, Provisioner}

  test "openclaw config disables the heartbeat and pins the model" do
    config = Provisioner.openclaw_config("gw-token", "https://poet.travel", "vendor/model-x")

    assert config.agents.defaults.heartbeat.every == "0m"
    assert config.agents.defaults.model == "openrouter/vendor/model-x"
    assert config.gateway.auth.token == "gw-token"
  end

  test "heartbeat acknowledgements are not treated as a poet's reply" do
    assert AgentSession.heartbeat_reply?("HEARTBEAT_OK")
    assert AgentSession.heartbeat_reply?("NO_REPLY")
    refute AgentSession.heartbeat_reply?("")
    refute AgentSession.heartbeat_reply?("I added the link to Liberty Public Market.")
  end
end
