defmodule TravelingPoet.AgentPluginTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Provisioner

  @source Provisioner.tpoet_plugin_source("https://poet.travel", "7.secret-token")

  # OpenClaw calls execute(toolCallId, params): the FIRST argument is the
  # tool-call id, params come second and may arrive as a JSON string. A handler
  # taking one argument therefore receives the ID where it expects the body.
  #
  # record_preference shipped that way and POSTed the tool-call id string as
  # its request body, which PreferenceController answered with a 422 "label is
  # required" every single time -- so nothing the poet was told in chat ever
  # reached learned_profile. Nothing failed loudly; the feature was just quietly
  # inert. No integration test was ever going to reach that, so it is pinned
  # here.
  test "every tool handler takes (toolCallId, params), never just params" do
    single_arg =
      Regex.scan(~r/execute:\s*(?:async\s+)?function\((\w+)\)/, @source)
      |> Enum.map(&List.last/1)

    assert single_arg == [],
           "these handlers take one argument and will be passed the tool-call id: #{inspect(single_arg)}"
  end

  test "every tool that sends a body routes it through asParams" do
    # Zero-parameter tools (the GETs) legitimately take no arguments at all.
    bodyless = ~w(get_conversation_memory get_poet_context get_feedback)

    for tool <- tool_names(), tool not in bodyless do
      body = tool_body(tool)

      assert body =~ "asParams(raw)",
             "#{tool} builds a request without normalising its params through asParams"
    end
  end

  test "the write tools the trip guide depends on are registered" do
    names = tool_names()

    for expected <- ~w(journal_upsert_entry journal_get_entry journal_put_sections
                       journal_put_places journal_publish generate_illustration
                       record_preference update_location hold_here insert_stop) do
      assert expected in names, "#{expected} is not registered in the plugin"
    end
  end

  test "the bearer token is baked in rather than read from the environment" do
    # OpenClaw's plugin scanner blocks env access combined with network send,
    # so this is deliberate -- and a regression to process.env would fail the
    # install on every sprite rather than at runtime.
    assert @source =~ ~s(var TOKEN = "7.secret-token")
    refute @source =~ "process.env"
  end

  defp tool_names do
    Regex.scan(~r/name:\s*"(\w+)"/, @source)
    |> Enum.map(&List.last/1)
    |> Enum.uniq()
  end

  # The slice of source between one tool's name and the next registration.
  defp tool_body(tool) do
    case String.split(@source, ~s(name: "#{tool}"), parts: 2) do
      [_, rest] -> rest |> String.split("ctx.registerTool(", parts: 2) |> hd()
      _ -> ""
    end
  end
end
