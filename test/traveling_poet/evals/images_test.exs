defmodule TravelingPoet.Evals.ImagesTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Evals.{ImageJudge, Images, ImagePage}

  defp manifest do
    %{
      "run_id" => "t",
      "candidates" => [
        %{"id" => "base", "model" => "g/base"},
        %{"id" => "cheap", "model" => "f/cheap"}
      ],
      "prompts" => [
        %{"id" => "p1", "kind" => "spot", "category" => "spot", "prompt" => "a door"},
        %{"id" => "p2", "kind" => "illustration", "category" => "place", "prompt" => "a bridge"},
        %{"id" => "p3", "kind" => "illustration", "category" => "place", "prompt" => "a hill"}
      ],
      "results" => [
        ok("p1", "base", 0.04, 6000, true),
        ok("p2", "base", 0.04, 7000, true),
        ok("p3", "base", 0.04, 8000, false),
        ok("p1", "cheap", 0.01, 2000, true),
        ok("p2", "cheap", 0.01, 3000, false),
        %{"prompt_id" => "p3", "candidate_id" => "cheap", "status" => "error", "error" => "500"}
      ],
      "blind" => %{}
    }
    |> Images.assign_blind("seed")
  end

  defp ok(p, c, cost, ms, pass) do
    %{
      "prompt_id" => p,
      "candidate_id" => c,
      "status" => "ok",
      "file" => "raw/#{p}/#{c}.png",
      "content_type" => "image/png",
      "cost" => cost,
      "ms" => ms,
      "screen" => %{"pass" => pass, "issues" => [], "reason" => ""}
    }
  end

  defp letter(m, pid, cid), do: Enum.find_value(m["blind"][pid], fn {l, c} -> c == cid && l end)

  test "every prompt gets every candidate under a distinct letter, stable across reruns" do
    m = manifest()

    for p <- ~w(p1 p2 p3) do
      assert m["blind"][p] |> Map.values() |> Enum.sort() == ["base", "cheap"]
      assert m["blind"][p] |> Map.keys() |> Enum.sort() == ["A", "B"]
    end

    assert Images.assign_blind(m, "another seed")["blind"] == m["blind"]
  end

  test "a candidate added later keeps the letters already voted on" do
    m = manifest()

    extended =
      m
      |> Map.update!("candidates", &(&1 ++ [%{"id" => "new", "model" => "n/new"}]))
      |> Images.assign_blind("seed")

    for p <- ~w(p1 p2 p3) do
      assert Map.take(extended["blind"][p], ["A", "B"]) == m["blind"][p]
      assert extended["blind"][p]["C"] == "new"
    end
  end

  test "tally reveals wins, publishable counts, failures, screen and cost" do
    m = manifest()

    votes = %{
      "votes" => %{
        "p1" => %{
          "best" => letter(m, "p1", "cheap"),
          "publishable" => [letter(m, "p1", "cheap"), letter(m, "p1", "base")]
        },
        "p2" => %{"best" => letter(m, "p2", "base"), "publishable" => [letter(m, "p2", "base")]}
      }
    }

    rows = Map.new(Images.tally(m, votes), &{&1.id, &1})

    assert %{wins: 1, publishable: 2, judged: 2, failed: 0, screen_pass: 2, screened: 3} =
             rows["base"]

    assert %{wins: 1, publishable: 1, failed: 1, attempted: 3, screen_pass: 1} = rows["cheap"]
    assert rows["cheap"].wins_by_category == %{"spot" => 1}
    assert_in_delta rows["base"].mean_cost, 0.04, 1.0e-9
    # two judged prompts, one publishable: $0.01 buys half a publishable drawing
    assert_in_delta rows["cheap"].cost_per_publishable, 0.02, 1.0e-9
    assert rows["base"].p50_ms == 7000

    md = Images.report_markdown(m, votes)
    assert md =~ "| base | 1 (50%) | 2 (100%) | 2/3 | 0/3 | $0.0400 |"
    assert md =~ "## Wins by category"
  end

  test "unknown candidate ids are refused" do
    assert_raise ArgumentError, ~r/unknown candidate/, fn -> Images.candidates(["nope"]) end
    assert [%{id: "gemini-2.5-flash"}] = Images.candidates(["gemini-2.5-flash"])
  end

  test "the prompt set is real prompts in the categories the report expects" do
    prompts = Images.load_prompts()
    assert length(prompts) >= 20
    assert prompts |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == length(prompts)

    assert prompts |> Enum.map(& &1["category"]) |> Enum.uniq() |> Enum.sort() ==
             ~w(excursion illustration place spot)

    for p <- prompts, do: assert(p["kind"] in ~w(spot illustration) and p["prompt"] != "")
  end

  @tag :tmp_dir
  test "the page names files by letter only and embeds no model id", %{tmp_dir: dir} do
    m = manifest()

    for %{"status" => "ok", "file" => f} <- m["results"] do
      File.mkdir_p!(Path.join(dir, Path.dirname(f)))
      File.write!(Path.join(dir, f), "png")
    end

    index = ImagePage.write(dir, m)
    html = File.read!(index)

    refute html =~ "cheap"
    refute html =~ "g/base"
    assert html =~ "no image (generation failed)"

    assert File.exists?(
             Path.join([dir, "page", "full", "p1", letter(m, "p1", "cheap") <> ".png"])
           )

    refute html =~ "—"
  end

  test "judge verdicts parse from bare or fenced JSON; anything else is unparseable" do
    assert {:ok, %{"pass" => false, "issues" => ["added text"], "subject" => 4}} =
             ImageJudge.parse_response(
               ~s(```json\n{"pass": false, "subject": 4, "issues": ["added text", 3], "reason": "a caption"}\n```)
             )

    assert {:ok, %{"pass" => true, "issues" => []}} =
             ImageJudge.parse_response(~s({"pass": true, "subject": 5, "reason": "fine"}))

    assert {:error, :unparseable} = ImageJudge.parse_response("looks good to me")
    assert {:error, :unparseable} = ImageJudge.parse_response(~s({"pass": "yes"}))
  end

  test "the judge sends the image inline and reads the verdict" do
    Req.Test.stub(TravelingPoet.Evals, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      assert body["model"] == "test/judge-model"
      [_, %{"content" => [_text, %{"image_url" => %{"url" => url}}]}] = body["messages"]
      assert url == "data:image/png;base64," <> Base.encode64("png")

      Req.Test.json(conn, %{
        "choices" => [
          %{"message" => %{"content" => ~s({"pass": true, "subject": 5, "reason": "ok"})}}
        ]
      })
    end)

    assert {:ok, %{"pass" => true}} =
             ImageJudge.screen("png", "image/png", "a door", "spot", api_key: "k")
  end
end
