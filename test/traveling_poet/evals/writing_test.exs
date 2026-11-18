defmodule TravelingPoet.Evals.WritingTest do
  use ExUnit.Case, async: false

  alias TravelingPoet.Evals.Writing
  alias TravelingPoet.Evals.Writing.{Checks, Judge}

  @tmp Path.join(System.tmp_dir!(), "writing-eval-test")

  setup do
    File.rm_rf!(@tmp)
    on_exit(fn -> File.rm_rf!(@tmp) end)
  end

  defp day(id, language) do
    %{
      "id" => id,
      "poet" => "Tal",
      "language" => language,
      "mission" => "wander",
      "excursion" => false,
      "entry_date" => "2026-11-09",
      "trigger" => "/travel-and-journal",
      "context" => ~s({"poet":{"language":"#{language}"}}),
      "research" => [
        %{"tool" => "web_fetch", "ref" => "https://example.org/kitano", "text" => "Kitano houses"}
      ],
      "files" => %{
        "skills/travel-and-journal/stay.md" => "STAY",
        "USER.md" => "USER",
        "AGENTS.md" => "AGENTS",
        "skills/travel-and-journal/SKILL.md" => "SKILL",
        "instructions.md" => "INSTR",
        "IDENTITY.md" => "IDENTITY"
      },
      "published" => %{
        "title" => "As published",
        "teaser" => "t",
        "sections" => [
          %{"kind" => "description", "title" => nil, "body" => "![x](/media/1)Words"}
        ]
      }
    }
  end

  defp page_json(body) do
    Jason.encode!(%{
      "title" => "Kobe",
      "teaser" => "Hills",
      "sections" => [%{"kind" => "description", "title" => "", "body" => body}]
    })
  end

  describe "parse/1" do
    test "takes the JSON out of fences and chatter, and drops drawings" do
      raw =
        "Here it is:\n```json\n" <>
          Jason.encode!(%{
            "title" => "Kobe",
            "sections" => [
              %{"kind" => "description", "body" => "![a](/media/9) The hills."},
              %{"kind" => "illustration", "body" => ""}
            ]
          }) <> "\n```"

      assert {:ok, %{"title" => "Kobe", "teaser" => "", "sections" => [s]}} = Checks.parse(raw)
      assert s == %{"kind" => "description", "title" => "", "body" => "The hills."}
    end

    test "says why a page could not be read" do
      assert {:error, "no JSON object in the answer"} = Checks.parse("I could not write today.")
      assert {:error, "invalid JSON"} = Checks.parse(~s({"title": "x", }))
      assert {:error, "no sections"} = Checks.parse(~s({"title": "x", "sections": []}))
      assert {:error, _} = Checks.parse(~s({"sections": [{"kind": "poem"}]}))
      assert {:error, "empty answer"} = Checks.parse(nil)
    end
  end

  describe "metrics/2" do
    test "a Hebrew page: share of Hebrew, words that mix scripts, letters in other scripts" do
      page = %{
        "title" => "קובה",
        "teaser" => "",
        "sections" => [
          %{
            "kind" => "description",
            "title" => "",
            "body" => "עליתי ל-Kitano ואל ה-UNESCO שלוםabc 神戸"
          }
        ]
      }

      m = Checks.metrics(page, "he")
      assert m["mixed_words"] == 1
      assert m["foreign_chars"] == 2
      assert m["hebrew_share"] < 0.9
      assert m["kinds"] == ["description"]
    end

    test "counts the disclaimers Udi found repeated, in both languages" do
      en = %{
        "title" => "",
        "teaser" => "",
        "sections" => [
          %{
            "kind" => "description",
            "title" => "",
            "body" =>
              "I haven't actually walked these hills; I am a virtual traveler. " <>
                "According to the website, it opens at nine. A fisherman told me the tide was late."
          }
        ]
      }

      assert %{"disclaimers" => 3} = Checks.metrics(en, "en")

      he = %{
        "title" => "",
        "teaser" => "",
        "sections" => [
          %{
            "kind" => "description",
            "title" => "",
            "body" => "אני לא באמת שם. לפי האתר, הבית נפתח בתשע. הדייג אמר שהגאות מאחרת."
          }
        ]
      }

      assert %{"disclaimers" => 2} = Checks.metrics(he, "he")
    end
  end

  test "the conversation: workspace files in production order, research, then the one instruction" do
    [system, user] = Writing.messages(day("d1", "he"))

    order =
      ~w(INSTR AGENTS IDENTITY USER SKILL STAY)
      |> Enum.map(fn marker -> :binary.match(system.content, marker) |> elem(0) end)

    assert order == Enum.sort(order)
    assert user.content =~ "/travel-and-journal"
    assert user.content =~ "### web_fetch: https://example.org/kitano\nKitano houses"
    assert user.content =~ "Your tools are switched off"
  end

  test "letters stay put across reruns and never repeat within a day" do
    manifest = %{
      "candidates" => Enum.map(~w(published a b c), &%{"id" => &1}),
      "days" => [%{"id" => "d1"}, %{"id" => "d2"}],
      "blind" => %{}
    }

    once = Writing.assign_blind(manifest, "seed")
    assert once["blind"]["d1"] |> Map.values() |> Enum.sort() == ~w(a b c published)

    grown =
      once
      |> Map.update!("candidates", &(&1 ++ [%{"id" => "d"}]))
      |> Writing.assign_blind("seed")

    assert Map.take(grown["blind"]["d1"], Map.keys(once["blind"]["d1"])) == once["blind"]["d1"]
    assert grown["blind"]["d1"]["E"] == "d"
  end

  test "judge verdicts parse and clamp, junk is refused" do
    assert {:ok, %{"broken" => 0, "fluency" => 5, "examples" => ["x"]}} =
             Judge.parse_response(~s(sure: {"broken": -1, "fluency": 9, "examples": ["x", 3]}))

    assert {:error, :unparseable} = Judge.parse_response(~s({"broken": "two"}))
  end

  test "a run: every candidate writes every day, the page is blind, the report reveals" do
    Req.Test.stub(TravelingPoet.Evals, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      message =
        cond do
          req["response_format"] ->
            %{
              "content" =>
                ~s({"broken": 1, "fluency": 4, "examples": ["bad line"], "reason": "ok"})
            }

          req["model"] == "z-ai/glm-5.3" ->
            %{"content" => "Sorry, I need my tools."}

          # The page comes back as the forced journal_write call.
          true ->
            assert req["tool_choice"]["function"]["name"] == "journal_write"
            assert [%{"function" => %{"name" => "journal_write"}}] = req["tools"]
            assert req["max_tokens"] == 32_768

            %{
              "content" => nil,
              "tool_calls" => [
                %{
                  "function" => %{
                    "name" => "journal_write",
                    "arguments" => page_json("Model page by #{req["model"]}")
                  }
                }
              ]
            }
        end

      Req.Test.json(conn, %{
        "choices" => [%{"message" => message}],
        "usage" => %{"cost" => 0.002, "prompt_tokens" => 900, "completion_tokens" => 300}
      })
    end)

    days = [day("d1", "he"), day("d2", "en")]
    candidates = Writing.candidates(~w(deepseek-v4-flash glm-5.3))
    run_dir = Path.join(@tmp, "run1")

    manifest = Writing.run(run_dir, days, candidates, api_key: "k")

    by = Map.new(manifest["results"], &{{&1["day_id"], &1["candidate_id"]}, &1})
    assert by[{"d1", "deepseek-v4-flash"}]["status"] == "ok"
    assert by[{"d1", "deepseek-v4-flash"}]["judge"]["broken"] == 1
    assert by[{"d1", "glm-5.3"}]["status"] == "unparsed"

    assert by[{"d1", "published"}]["page"]["sections"] == [
             %{"kind" => "description", "title" => "", "body" => "Words"}
           ]

    html = File.read!(Path.join(run_dir, "page/index.html"))
    assert html =~ "Model page by deepseek/deepseek-v4-flash"
    refute html =~ "deepseek-v4-flash\""
    refute html =~ "glm-5.3\""
    refute html =~ ~s("published")

    # Rerunning keeps what is done: only the failed page is asked for again.
    test_pid = self()

    Req.Test.stub(TravelingPoet.Evals, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:asked, Jason.decode!(body)["model"]})
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => page_json("again")}}]})
    end)

    again = Writing.run(run_dir, days, candidates, api_key: "k", judge: false)
    assert_received {:asked, "z-ai/glm-5.3"}
    refute_received {:asked, "deepseek/deepseek-v4-flash"}
    assert again["blind"] == manifest["blind"]

    letter = fn day, id ->
      Enum.find_value(again["blind"][day], &(elem(&1, 1) == id && elem(&1, 0)))
    end

    votes = %{
      "votes" => %{
        "d1" => %{
          "best" => letter.("d1", "deepseek-v4-flash"),
          "publishable" => [],
          "gibberish" => [letter.("d1", "published")]
        },
        "d2" => %{
          "best" => letter.("d2", "published"),
          "publishable" => [letter.("d2", "glm-5.3")]
        }
      }
    }

    rows = Map.new(Writing.tally(again, votes), &{&1.id, &1})
    assert rows["deepseek-v4-flash"].wins == 1
    assert rows["deepseek-v4-flash"].wins_by_language == %{"he" => 1}
    assert rows["published"].wins_by_language == %{"en" => 1}
    assert rows["published"].gibberish == 1
    assert rows["glm-5.3"].publishable == 1
    assert rows["deepseek-v4-flash"].broken_sentences == 1.0

    assert Writing.report_markdown(again, votes) =~ "| deepseek-v4-flash | 1 (50%) | 1 / 0 |"
  end
end
