defmodule TravelingPoet.AppLoopTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.AppLoop.{Draft, Run, Runner, Shadow, Tools, Web}
  alias TravelingPoet.{Journal, Provisioner, Repo}

  @date ~D[2026-11-18]

  setup do
    Application.put_env(:traveling_poet, :openrouter_api_key, "test-key")
    on_exit(fn -> Application.delete_env(:traveling_poet, :openrouter_api_key) end)
    :ok
  end

  describe "tools" do
    test "every plugin tool is read out of the plugin source, routed or not offered" do
      specs = Tools.plugin_specs()
      names = Enum.map(specs, & &1["name"])

      assert names == Provisioner.tpoet_plugin_tools()

      for spec <- specs do
        assert is_binary(spec["description"]) and spec["description"] != ""
        assert is_map(spec["parameters"])
      end

      for name <- names, name not in Tools.not_offered() do
        assert Tools.route(name, %{"entry_date" => "2026-11-18"}),
               "#{name} has no route: route it in AppLoop.Tools or list it as not offered"
      end

      offered = Enum.map(Tools.definitions(), & &1.function.name)
      assert offered == Enum.uniq(offered)
      assert "web_search" in offered and "web_fetch" in offered and "read" in offered
      refute "journal_upload_illustration" in offered
    end

    test "a sprite poet and an app poet get the same words for a tool" do
      upsert = Enum.find(Tools.definitions(), &(&1.function.name == "journal_upsert_entry"))
      assert upsert.function.description =~ "idempotent by date"
      # a JS string with a colon and braces in it survives as written
      assert upsert.function.parameters["properties"]["sources"]["description"] ==
               "grounding URLs, e.g. {wikipedia: ..., news: ...}"
    end

    test "object literals become JSON only outside strings" do
      js = ~S|{ a: "x: {y: 1,}", b: [1, 2,], }|
      assert Jason.decode!(Tools.js_object_to_json(js)) == %{"a" => "x: {y: 1,}", "b" => [1, 2]}
    end
  end

  describe "web" do
    test "a page becomes its readable text" do
      html = """
      <html><head><title>Bells &amp; bees</title><script>evil()</script></head>
      <body><nav>Home | About</nav><p>The bell-ringer keeps&nbsp;bees.</p><p>&#8220;Tide&#8221; bread</p></body></html>
      """

      text = Web.html_to_text(html)
      assert text == "The bell-ringer keeps bees.\n\n“Tide” bread"
    end

    test "fetch refuses local, internal and literal-IP hosts" do
      for url <-
            ~w(http://localhost/x http://127.0.0.1/ http://[::1]/ http://app.internal/ http://10.0.0.1/ ftp://x.com/) do
        assert {:error, _} = Web.fetch(url), url
      end

      assert Web.internal_ip?({169, 254, 169, 254})
      assert Web.internal_ip?({0xFDAA, 0, 0, 0, 0, 0, 0, 1})
      refute Web.internal_ip?({93, 184, 216, 34})
    end

    test "fetch follows a redirect only to an allowed host" do
      Req.Test.stub(TravelingPoet.AppLoop, fn conn ->
        case conn.host do
          "a.example" ->
            conn
            |> Plug.Conn.put_resp_header("location", "http://localhost/secret")
            |> Plug.Conn.send_resp(302, "")
        end
      end)

      assert {:error, "that host is not allowed"} = Web.fetch("http://a.example/")
    end
  end

  describe "draft" do
    test "publishing tells the poet what the page lacks, the way the app does" do
      d = Draft.new(@date, "stay")
      {404, _, d} = Draft.apply(d, "journal_publish", %{"entry_date" => "2026-11-18"})

      {200, _, d} =
        Draft.apply(d, "journal_upsert_entry", %{"entry_date" => "2026-11-18", "title" => "T"})

      {200, %{"section_count" => 1, "note" => note}, d} =
        Draft.apply(d, "journal_put_sections", %{
          "entry_date" => "2026-11-18",
          "sections" => [
            %{"kind" => "description", "body" => "Words."},
            %{"kind" => "poem", "title" => "x"}
          ]
        })

      assert note =~ "had no body"

      {200, reply, d} = Draft.apply(d, "journal_publish", %{"entry_date" => "2026-11-18"})
      assert reply["missing"] == ["places", "drawing"]
      assert reply["note"] =~ "journal_put_places"
      assert Draft.published?(d)

      # a quiz day needs its quiz, nothing else
      q = %{Draft.new(@date, "quiz") | entry: %{}}
      assert Draft.missing(q) == ["quiz"]
    end

    test "a write for another day is refused, never let through" do
      d = Draft.new(@date, "stay")

      assert {422, %{"error" => "today's entry is 2026-11-18; write that date"}, ^d} =
               Draft.apply(d, "journal_upsert_entry", %{"entry_date" => "2026-11-17"})
    end
  end

  # A scripted model: each reply in turn, and every request it was sent.
  defp script_model(replies) do
    {:ok, agent} = Agent.start_link(fn -> {replies, []} end)

    Req.Test.stub(TravelingPoet.AppLoop, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      reply =
        Agent.get_and_update(agent, fn {[next | rest], seen} ->
          {next, {rest, seen ++ [request]}}
        end)

      Req.Test.json(conn, %{
        "choices" => [%{"message" => Map.put(reply, "role", "assistant")}],
        "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 10, "cost" => 0.001}
      })
    end)

    agent
  end

  defp call(id, name, args) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => if(is_binary(args), do: args, else: Jason.encode!(args))
      }
    }
  end

  defp tools(calls), do: %{"content" => "", "tool_calls" => calls}

  defp a_day do
    [
      tools([
        call("c1", "get_poet_context", %{}),
        call("c2", "read", %{"path" => "skills/travel-and-journal/quiz.md"})
      ]),
      tools([call("c3", "get_feedback", %{})]),
      tools([call("c4", "journal_upsert_entry", "{not json")]),
      tools([
        call("c5", "journal_upsert_entry", %{
          "entry_date" => "2026-11-18",
          "title" => "Bees in the tower",
          "teaser" => "He named every one."
        })
      ]),
      tools([
        call("c6", "journal_put_sections", %{
          "entry_date" => "2026-11-18",
          "sections" => [%{"kind" => "description", "body" => "The bell-ringer keeps bees."}]
        }),
        call("c7", "update_location", %{"lat" => 1, "lng" => 2, "place_name" => "Sintra"}),
        call("c8", "rm_rf", %{})
      ]),
      tools([call("c9", "journal_publish", %{"entry_date" => "2026-11-18"})]),
      %{"content" => "Published."}
    ]
  end

  defp inputs(user, poet) do
    %{
      user: user,
      poet: poet,
      model: "test/model",
      system: "You are a poet.",
      trigger: "/travel-and-journal",
      entry_date: @date,
      context:
        Jason.encode!(%{"result" => %{"travel" => %{"day" => "stay"}, "poet" => %{"name" => "N"}}}),
      day: "stay",
      files: %{"skills/travel-and-journal/quiz.md" => "Quiz rules."}
    }
  end

  describe "the loop" do
    test "writes a day into the draft and nothing into the journal" do
      user = agent_user_fixture()
      poet = poet_fixture(user)
      location = {poet.current_lat, poet.current_place_name}
      agent = script_model(a_day())

      result = Runner.run(inputs(user, poet), shadow: true)

      assert result.status == "published"
      assert result.model_calls == 7
      assert result.tool_calls == 9
      assert result.malformed_calls == 1
      # the malformed call, the unknown tool
      assert result.tool_errors == 2
      assert_in_delta result.cost, 0.007, 1.0e-9
      assert result.final_text == "Published."

      assert result.draft.entry["title"] == "Bees in the tower"
      assert [%{"tool" => "update_location"}] = result.draft.actions

      # nothing reached the reader
      assert Journal.get_entry(poet.id, @date) == nil
      poet = Repo.reload!(poet)
      assert {poet.current_lat, poet.current_place_name} == location

      {_, requests} = Agent.get(agent, & &1)
      [first | _] = requests
      assert Enum.any?(first["tools"], &(&1["function"]["name"] == "journal_put_quiz"))

      tool_reply = fn id ->
        requests
        |> List.last()
        |> Map.fetch!("messages")
        |> Enum.find(&(&1["tool_call_id"] == id))
        |> Map.fetch!("content")
        |> Jason.decode!()
      end

      # the frozen context, wrapped once as the plugin wraps it
      assert tool_reply.("c1") == %{
               "result" => %{"travel" => %{"day" => "stay"}, "poet" => %{"name" => "N"}}
             }

      assert tool_reply.("c2")["content"] == "Quiz rules."
      # a real read, through the real endpoint and its auth
      assert %{"result" => %{"engagement" => _}} = tool_reply.("c3")
      assert tool_reply.("c4")["error"] =~ "not valid JSON"
      assert tool_reply.("c8")["error"] =~ "no tool called rm_rf"

      assert %{"result" => %{"ok" => true, "missing" => ["places", "drawing"]}} =
               tool_reply.("c9")
    end

    test "a read with a query string reaches the endpoint whole" do
      user = agent_user_fixture()
      test_pid = self()

      Req.Test.stub(TravelingPoet.Commons, fn conn ->
        send(test_pid, {:commons, conn.query_string})
        Req.Test.json(conn, %{})
      end)

      {method, path, body} =
        Tools.route("find_reference_photos", %{"query" => "Finnieston Crane", "limit" => 3})

      {:ok, status, _reply} = TravelingPoet.AppLoop.Dispatch.call(user, method, path, body)

      refute status == 422
      assert_received {:commons, query}
      assert URI.decode_www_form(query) =~ "Finnieston Crane"
    end

    test "a model that never stops is cut off" do
      user = agent_user_fixture()
      poet = poet_fixture(user)
      script_model(List.duplicate(tools([call("x", "get_poet_context", %{})]), 5))

      result = Runner.run(inputs(user, poet), shadow: true, max_model_calls: 3)
      assert result.status == "limit"
      assert result.model_calls == 3
    end
  end

  describe "shadow" do
    test "replays the sprite's published run and keeps the result" do
      user = agent_user_fixture()
      poet = poet_fixture(user, %{settings: %{"app_loop" => "shadow"}})
      script_model(a_day())

      sprite_run = %{
        "files" => %{
          "AGENTS.md" => "Rules.",
          "skills/travel-and-journal/SKILL.md" => "The skill.",
          "skills/travel-and-journal/quiz.md" => "Quiz rules."
        },
        "runs" => [
          %{"prompt" => "/travel-and-journal", "entry_date" => "2026-11-17", "results" => []},
          %{
            "prompt" => "/travel-and-journal\nToday is a quiz day",
            "entry_date" => "2026-11-18",
            "results" => [
              %{"tool" => "get_poet_context", "text" => ~s({"result":{"travel":{"day":"quiz"}}})}
            ]
          }
        ]
      }

      {:ok, inputs} = Shadow.inputs_for(Repo.preload(poet, :user), @date, sprite_run: sprite_run)
      assert inputs.day == "quiz"
      assert inputs.trigger =~ "quiz day"
      assert inputs.system =~ "=== AGENTS.md ===\nRules."
      assert inputs.system =~ "The skill."
      # a day file is read on demand, not put in the prompt
      refute inputs.system =~ "Quiz rules."
      # the sprite's copy of a file wins; any other skill comes from the seed
      assert inputs.files["skills/travel-and-journal/quiz.md"] == "Quiz rules."
      assert inputs.files["skills/poem/SKILL.md"] =~ "poem"

      assert {:ok, %Run{} = run} = Shadow.run(poet.id, @date, sprite_run: sprite_run)
      assert run.status == "published"
      assert run.malformed_calls == 1
      assert run.page["title"] == "Bees in the tower"
      assert length(run.steps["items"]) == 9
      assert [%Run{}] = Shadow.runs(poet.id)

      # no day to replay
      assert {:ok, %Run{status: "no_input"}} =
               Shadow.run(poet.id, ~D[2026-11-19], sprite_run: sprite_run)
    end

    test "a poet not in shadow mode is left alone" do
      user = agent_user_fixture()
      poet = poet_fixture(user)
      published_entry_fixture(poet, %{entry_date: @date})
      assert Shadow.after_publish(user, poet) == :ok
      refute Shadow.enabled?(poet)
    end
  end
end
