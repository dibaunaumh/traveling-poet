defmodule TravelingPoet.Evals.SearchTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Evals.Search
  alias TravelingPoet.Evals.Search.{Judge, Providers, Queries}

  describe "collecting queries from transcripts" do
    test "grep output with stream-frame bytes parses into calls" do
      out =
        <<1>> <>
          ~s(main/sessions/a.jsonl:"name":"web_search","arguments":{"query":"Cádiz weather","count":3}\n) <>
          ~s(main/sessions/a.jsonl.reset.2026-09-17T15-05-09.648Z:"name":"web_fetch","arguments":{"url":"https://x.org"}\n) <>
          ~s(main/sessions/b.jsonl:"name":"web_search","arguments":{"query":broken\n)

      calls = Queries.parse("s1", out)

      assert [
               %{
                 sprite: "s1",
                 file: "a.jsonl",
                 tool: "web_search",
                 arguments: %{"query" => "Cádiz weather", "count" => 3}
               },
               %{tool: "web_fetch", file: "a.jsonl.reset.2026-09-17T15-05-09.648Z"}
             ] = calls

      assert [
               %{sprite: "s1", file: "a.jsonl", searches: 1, fetches: 0},
               %{searches: 0, fetches: 1}
             ] =
               calls |> Queries.per_session() |> Enum.sort_by(& &1.file)
    end

    test "the sample is stable, deduplicated and capped per sprite" do
      calls =
        for s <- ~w(s1 s2), q <- ~w(alpha beta gamma Alpha) do
          %{
            sprite: s,
            file: "f",
            tool: "web_search",
            arguments: %{"query" => "#{s} #{q}", "count" => 3}
          }
        end ++ [%{sprite: "s1", file: "f", tool: "web_fetch", arguments: %{"url" => "u"}}]

      sample = Queries.sample(calls, 2)
      assert length(sample) == 4
      assert sample == Queries.sample(Enum.reverse(calls), 2)
      assert Enum.map(sample, & &1["id"]) == ~w(q01 q02 q03 q04)
      assert Enum.all?(sample, &(&1["count"] == 3 and not Map.has_key?(&1, "freshness")))
    end

    test "the committed replay set is well formed" do
      queries = Search.load_queries()
      assert length(queries) >= 40
      assert queries |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == length(queries)
      assert Enum.all?(queries, &(is_binary(&1["query"]) and &1["query"] != ""))
    end
  end

  describe "providers" do
    test "Sonar gets exactly the query as a user message, and freshness as a recency filter" do
      Req.Test.stub(TravelingPoet.Evals, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(body)
        assert conn.request_path == "/api/v1/chat/completions"
        assert body["model"] == "perplexity/sonar"
        assert body["messages"] == [%{"role" => "user", "content" => "Seville art"}]
        assert body["search_recency_filter"] == "week"

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "Answer [1]"}}],
          "citations" => ["https://a.org", "https://a.org", "https://b.org"],
          "usage" => %{"cost" => 0.005}
        })
      end)

      assert {:ok, %{answer: "Answer [1]", urls: ["https://a.org", "https://b.org"], cost: 0.005}} =
               Providers.search(:sonar, %{"query" => "Seville art", "freshness" => "week"},
                 api_key: "k"
               )
    end

    test "citations fall back to url_citation annotations" do
      resp = %{
        "choices" => [
          %{
            "message" => %{
              "annotations" => [
                %{"type" => "url_citation", "url_citation" => %{"url" => "https://c.org"}},
                %{"type" => "other", "url" => "https://nope.org"}
              ]
            }
          }
        ]
      }

      assert Providers.sonar_citations(resp) == ["https://c.org"]
    end

    test "Tavily: count becomes max_results, depth by provider, cost from credits" do
      Req.Test.stub(TravelingPoet.Evals, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(body)
        assert conn.host == "api.tavily.com"
        assert body["max_results"] == 3
        assert body["search_depth"] == "advanced"

        Req.Test.json(conn, %{
          "results" => [
            %{
              "url" => "https://v.org/p",
              "title" => "V",
              "content" => "Sep 25",
              "published_date" => "2026-09-01"
            },
            %{"title" => "no url"}
          ],
          "usage" => %{"credits" => 2}
        })
      end)

      assert {:ok,
              %{urls: ["https://v.org/p"], results: [%{published: "2026-09-01"}], cost: cost}} =
               Providers.search(:tavily_advanced, %{"query" => "q", "count" => 3}, api_key: "t")

      assert_in_delta cost, 0.016, 1.0e-9
    end

    test "unknown provider names are refused" do
      assert Providers.parse!("sonar,tavily_basic") == [:sonar, :tavily_basic]
      assert_raise ArgumentError, ~r/unknown provider/, fn -> Providers.parse!("bing") end
    end
  end

  describe "judge" do
    test "verdicts parse, clamp, and drop junk" do
      assert {:ok,
              %{
                "answers" => 5,
                "specific_facts" => 4,
                "current" => nil,
                "sourced" => 1,
                "suspect" => ["x"]
              }} =
               Judge.parse_response(
                 ~s(Here: {"answers": 9, "specific_facts": 4, "sourced": 0, "current": null, "suspect": ["x", 2], "reason": "ok"})
               )

      assert {:error, :unparseable} = Judge.parse_response(~s({"answers": "high"}))
    end

    test "the judge sees answer and sources, never the provider" do
      text =
        Judge.render(%{
          "answer" => nil,
          "results" => [
            %{"url" => "https://v.org", "title" => "V", "snippet" => "s", "published" => nil}
          ]
        })

      assert text =~ "ANSWER:\n(none)"
      assert text =~ "[1] https://v.org\n    title: V\n    snippet: s"
      refute text =~ ~r/tavily|sonar|perplexity/i
    end
  end

  test "summary and report per provider" do
    run = %{
      "run_id" => "t",
      "queries" => [%{"id" => "q01", "query" => "a | b"}, %{"id" => "q02", "query" => "c"}],
      "results" => [
        result("q01", "sonar_pro", 0.01, 3, 4, 2, 2),
        result("q02", "sonar_pro", 0.01, 1, 2, 1, 2),
        result("q01", "tavily_basic", 0.008, 4, 6, 5, 5),
        %{
          "query_id" => "q02",
          "provider" => "tavily_basic",
          "status" => "error",
          "error" => "500"
        }
      ]
    }

    [pro, tav] = Search.summarize(run)
    assert %{provider: "sonar_pro", answers: 2.0, facts: 3.0, errors: 0, links_alive: 0.75} = pro
    assert_in_delta pro.cost_per_fact, 0.02 / 6, 1.0e-9
    assert %{provider: "tavily_basic", errors: 1, facts: 6.0, links_alive: 1.0} = tav

    md = Search.report_markdown(run)
    assert md =~ "| sonar_pro | 2.0 | 3.0 |"
    assert md =~ "| q01 a / b | 3 / 4 | 4 / 6 |"
    assert md =~ "| q02 c | 1 / 2 | error |"
  end

  defp result(q, p, cost, answers, facts, alive, checked) do
    %{
      "query_id" => q,
      "provider" => p,
      "status" => "ok",
      "result" => %{"cost" => cost, "ms" => 1000, "urls" => ["u"], "results" => []},
      "links" => %{"checked" => checked, "alive" => alive},
      "score" => %{
        "answers" => answers,
        "specific_facts" => facts,
        "sourced" => 3,
        "current" => nil,
        "right_urls" => nil,
        "suspect" => []
      }
    }
  end
end
