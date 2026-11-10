defmodule TravelingPoet.Evals.Writing do
  @moduledoc """
  Blind eval of text models writing a poet's daily page.

  Driven by `mix tpoet.eval_writing`, never by `mix test` or the request
  path: every run spends real money on OpenRouter.

  The days come from `Evals.Writing.Days`, frozen on production: what one
  real poet had on one real day (its instructions and skill, its context,
  every page it searched or fetched). Each candidate gets the same day and
  writes the page in one reply, tools switched off, so the eval compares
  writing, not search luck or tool handling. Tool reliability is the second
  stage, for finalists only, on a test poet.

  One run lives in `evals/writing/<run_id>/`:

    * `manifest.json` - candidates, days (without their research, which stays
      in the days file), one result per day and candidate (page, automatic
      checks, language judge, cost, latency, error) and the blind letters
    * `raw/<day>/<candidate>.txt` - each answer as the model returned it
    * `page/index.html` - the judging page, by letter only

  What readers actually got that day rides along as the blind candidate
  `published`, so the report also says whether a model beats the page as
  it went out.

  Generation is resumable: rerunning a run id keeps every page already
  written.
  """

  alias TravelingPoet.Evals.Writing.{Checks, Judge, Page}

  @api_url "https://openrouter.ai/api/v1/chat/completions"

  @baseline "deepseek-v4-flash"
  @published "published"

  # OpenRouter's listing on 2026-11-10, $ per Mtok in / out; the report uses
  # the cost OpenRouter returns, these are only for planning.
  @candidates [
    %{id: @baseline, model: "deepseek/deepseek-v4-flash", list: {0.091, 0.182}},
    %{id: "deepseek-v4.1-flash", model: "deepseek/deepseek-v4.1-flash-1017", list: {0.006, 0.5}},
    %{id: "glm-5.3", model: "z-ai/glm-5.3", list: {0.07, 1.4}},
    %{id: "glm-5.3-flash", model: "z-ai/glm-5.3-flash", list: {0.04, 0.078}},
    %{id: "qwen3.8-flash", model: "qwen/qwen3.8-flash", list: {0.15, 0.47}},
    %{id: "minimax-m3.1-flash", model: "minimax/minimax-m3.1-flash", list: {0.075, 0.3}},
    %{id: "mimo-v2.6-flash", model: "xiaomi/mimo-v2.6-flash", list: {0.14, 0.28}},
    %{id: "mistral-large-4", model: "mistralai/mistral-large-4-0", list: {0.7, 2.1}}
  ]

  @letters ~w(A B C D E F G H I J K L)

  def candidates, do: @candidates
  def baseline, do: @baseline

  def candidates(nil), do: @candidates

  def candidates(ids) when is_list(ids) do
    Enum.map(ids, fn id ->
      Enum.find(@candidates, &(&1.id == id)) ||
        raise ArgumentError,
              "unknown candidate #{inspect(id)}; known: #{Enum.map_join(@candidates, ", ", & &1.id)}"
    end)
  end

  def load_days(path), do: path |> File.read!() |> Jason.decode!() |> Map.fetch!("days")

  @doc """
  Writes every missing page, checks and judges them, and writes the judging
  page. Returns the manifest.
  """
  def run(run_dir, days, candidates, opts \\ []) do
    File.mkdir_p!(run_dir)
    log = Keyword.get(opts, :log, fn _ -> :ok end)
    api = Keyword.take(opts, [:api_key])

    (load_manifest(run_dir) || new_manifest(run_dir))
    |> add_days(days)
    |> add_published(days)
    |> generate(run_dir, days, candidates, log, api)
    |> then(fn m -> if Keyword.get(opts, :judge, true), do: judge(m, log, api), else: m end)
    |> assign_blind(Keyword.get(opts, :seed, Path.basename(run_dir)))
    |> tap(&save_manifest(run_dir, &1))
    |> tap(&Page.write(run_dir, &1, days))
  end

  defp new_manifest(run_dir) do
    %{
      "run_id" => Path.basename(run_dir),
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "candidates" => [%{"id" => @published, "model" => nil}],
      "days" => [],
      "results" => [],
      "blind" => %{}
    }
  end

  defp add_days(manifest, days) do
    known = Enum.map(manifest["days"], & &1["id"])

    new =
      days
      |> Enum.reject(&(&1["id"] in known))
      |> Enum.map(&Map.take(&1, ~w(id poet language mission excursion entry_date)))

    Map.put(manifest, "days", manifest["days"] ++ new)
  end

  # What readers got that day, measured like any other candidate.
  defp add_published(manifest, days) do
    have = for r <- manifest["results"], r["candidate_id"] == @published, do: r["day_id"]

    fresh =
      for d <- days, d["id"] not in have do
        page = %{
          "title" => d["published"]["title"] || "",
          "teaser" => d["published"]["teaser"] || "",
          "sections" =>
            Enum.map(d["published"]["sections"], fn s ->
              %{
                "kind" => s["kind"],
                "title" => s["title"] || "",
                "body" => Regex.replace(~r/!\[[^\]]*\]\([^)]*\)/, s["body"] || "", "")
              }
            end)
        }

        %{
          "day_id" => d["id"],
          "candidate_id" => @published,
          "status" => "ok",
          "page" => page,
          "metrics" => Checks.metrics(page, d["language"])
        }
      end

    Map.update!(manifest, "results", &(&1 ++ fresh))
  end

  defp generate(manifest, run_dir, days, candidates, log, api) do
    done =
      for %{"status" => "ok"} = r <- manifest["results"],
          into: MapSet.new(),
          do: {r["day_id"], r["candidate_id"]}

    todo =
      for d <- days, c <- candidates, not MapSet.member?(done, {d["id"], c.id}), do: {d, c}

    already = Enum.count(done, fn {_, cid} -> cid != @published end)
    log.("writing #{length(todo)} pages (#{already} already done)")

    fresh =
      todo
      |> Task.async_stream(fn {d, c} -> write_one(run_dir, d, c, log, api) end,
        max_concurrency: 4,
        timeout: 420_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, result} -> [result]
        {:exit, _} -> []
      end)

    fresh_keys = Enum.map(fresh, &{&1["day_id"], &1["candidate_id"]})
    kept = Enum.reject(manifest["results"], &({&1["day_id"], &1["candidate_id"]} in fresh_keys))

    manifest
    |> Map.put("results", kept ++ fresh)
    |> Map.put("candidates", merge_candidates(manifest["candidates"], candidates))
  end

  defp merge_candidates(existing, candidates) do
    ids = Enum.map(existing, & &1["id"])

    existing ++
      (candidates
       |> Enum.reject(&(&1.id in ids))
       |> Enum.map(&%{"id" => &1.id, "model" => &1.model}))
  end

  defp write_one(run_dir, day, candidate, log, api) do
    base = %{"day_id" => day["id"], "candidate_id" => candidate.id}

    case chat(candidate.model, messages(day), api) do
      {:ok, %{content: raw} = res} ->
        rel = Path.join(["raw", day["id"], "#{candidate.id}.txt"])
        path = Path.join(run_dir, rel)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, raw)

        stats = %{
          "raw" => rel,
          "cost" => res.cost,
          "ms" => res.ms,
          "tokens_in" => res.tokens_in,
          "tokens_out" => res.tokens_out
        }

        case Checks.parse(raw) do
          {:ok, page} ->
            log.("  ok    #{day["id"]} / #{candidate.id} (#{res.ms}ms, $#{res.cost})")

            base
            |> Map.merge(stats)
            |> Map.merge(%{
              "status" => "ok",
              "page" => page,
              "metrics" => Checks.metrics(page, day["language"])
            })

          {:error, reason} ->
            log.("  bad   #{day["id"]} / #{candidate.id}: #{reason}")
            base |> Map.merge(stats) |> Map.merge(%{"status" => "unparsed", "error" => reason})
        end

      {:error, reason} ->
        log.("  error #{day["id"]} / #{candidate.id}: #{inspect(reason)}")
        Map.merge(base, %{"status" => "error", "error" => inspect(reason)})
    end
  end

  @doc """
  The conversation one candidate gets for one day: the poet's workspace
  files as the system prompt, then the app's trigger with everything the
  poet's tools returned that day, then the eval's one instruction.
  """
  def messages(day) do
    files = day["files"] || %{}

    {skill, rest} =
      files
      |> Map.keys()
      |> Enum.split_with(&(&1 == "skills/travel-and-journal/SKILL.md"))

    order =
      Enum.filter(~w(instructions.md AGENTS.md IDENTITY.md USER.md), &Map.has_key?(files, &1)) ++
        skill ++ Enum.sort(rest -- ~w(instructions.md AGENTS.md IDENTITY.md USER.md))

    system = Enum.map_join(order, "\n\n", &"=== #{&1} ===\n#{files[&1]}")

    research =
      Enum.map_join(day["research"], "\n\n", fn r ->
        "### #{r["tool"]}: #{r["ref"]}\n#{r["text"]}"
      end)

    user = """
    #{day["trigger"]}

    ---
    What your tools returned today:

    ### get_poet_context
    #{day["context"]}

    #{research}

    ---
    #{instruction()}
    """

    [%{role: "system", content: system}, %{role: "user", content: user}]
  end

  @doc false
  def instruction do
    """
    EVAL RUN. Your tools are switched off for this one reply. Above is everything you
    gathered for today: get_poet_context and every page you searched or fetched. Do not
    ask for more; write from this.

    Write today's journal entry now, exactly as you would send it with
    journal_upsert_entry and journal_put_sections, following your skill, AGENTS.md and
    the language your context names. Leave out drawings: no illustration sections and
    no images in any body.

    Answer with one JSON object and nothing else:
    {"title": "...", "teaser": "...", "sections": [{"kind": "...", "title": "...", "body": "markdown"}]}
    """
  end

  @doc """
  One OpenRouter chat completion: `{:ok, %{content, cost, ms, tokens_in,
  tokens_out}}` or `{:error, reason}`. `json: true` asks for a JSON object.
  """
  def chat(model, messages, opts \\ []) do
    key = Keyword.get(opts, :api_key, Application.get_env(:traveling_poet, :openrouter_api_key))

    if key in [nil, ""] do
      {:error, :not_configured}
    else
      body =
        %{
          model: model,
          messages: messages,
          max_tokens: Keyword.get(opts, :max_tokens, 12_000),
          usage: %{include: true}
        }
        |> then(
          &if opts[:json], do: Map.put(&1, :response_format, %{type: "json_object"}), else: &1
        )

      req_opts =
        [
          json: body,
          headers: [{"authorization", "Bearer #{key}"}],
          receive_timeout: 400_000,
          retry: :transient
        ] ++ Application.get_env(:traveling_poet, :eval_req_options, [])

      started = System.monotonic_time(:millisecond)

      case Req.post(@api_url, req_opts) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => msg} | _]} = b}} ->
          usage = b["usage"] || %{}

          {:ok,
           %{
             content: msg["content"] || "",
             cost: usage["cost"],
             tokens_in: usage["prompt_tokens"],
             tokens_out: usage["completion_tokens"],
             ms: System.monotonic_time(:millisecond) - started
           }}

        {:ok, %{status: status, body: b}} ->
          {:error, "#{status}: #{b |> inspect() |> String.slice(0, 300)}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp judge(manifest, log, api) do
    languages = Map.new(manifest["days"], &{&1["id"], &1["language"]})
    pending = Enum.filter(manifest["results"], &(&1["status"] == "ok" and is_nil(&1["judge"])))
    log.("judging the language of #{length(pending)} pages with #{Judge.model()}")

    judged =
      pending
      |> Task.async_stream(
        fn r ->
          case Judge.language(r["page"], languages[r["day_id"]], api) do
            {:ok, verdict} ->
              {r, verdict}

            {:error, reason} ->
              log.("  judge failed #{r["day_id"]} / #{r["candidate_id"]}: #{inspect(reason)}")
              {r, nil}
          end
        end,
        max_concurrency: 4,
        timeout: 180_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {r, verdict}} when is_map(verdict) -> [{{r["day_id"], r["candidate_id"]}, verdict}]
        _ -> []
      end)
      |> Map.new()

    Map.update!(manifest, "results", fn rs ->
      Enum.map(rs, fn r ->
        case judged[{r["day_id"], r["candidate_id"]}] do
          nil -> r
          verdict -> Map.put(r, "judge", verdict)
        end
      end)
    end)
  end

  @doc """
  Gives each day's candidates a letter in a shuffled order that depends only
  on the seed and the day, so reruns keep the letters a judge may already
  have voted on. Existing assignments are never reshuffled.
  """
  def assign_blind(manifest, seed) do
    ids = Enum.map(manifest["candidates"], & &1["id"])

    blind =
      Map.new(manifest["days"], fn d ->
        existing = get_in(manifest, ["blind", d["id"]]) || %{}
        assigned = Map.values(existing)

        new_ids =
          ids
          |> Enum.reject(&(&1 in assigned))
          |> Enum.sort_by(&:crypto.hash(:sha256, "#{seed}:#{d["id"]}:#{&1}"))

        free = @letters -- Map.keys(existing)
        {d["id"], Map.merge(existing, Map.new(Enum.zip(free, new_ids)))}
      end)

    Map.put(manifest, "blind", blind)
  end

  @doc """
  Reveals a judged run. `votes` is the page's export: `%{"votes" => %{day_id
  => %{"best" => letter, "publishable" => [..], "gibberish" => [..],
  "preachy" => [..]}}}`. One row per candidate.
  """
  def tally(manifest, votes) do
    by_day = votes["votes"] || %{}
    judged = Map.keys(by_day)
    languages = Map.new(manifest["days"], &{&1["id"], &1["language"]})

    Enum.map(manifest["candidates"], fn c ->
      id = c["id"]
      results = Enum.filter(manifest["results"], &(&1["candidate_id"] == id))
      ok = Enum.filter(results, &(&1["status"] == "ok"))

      letter_of = fn day ->
        Enum.find_value(manifest["blind"][day] || %{}, &(elem(&1, 1) == id && elem(&1, 0)))
      end

      marked = fn key -> Enum.count(judged, &(letter_of.(&1) in (by_day[&1][key] || []))) end
      wins = Enum.filter(judged, &(by_day[&1]["best"] == letter_of.(&1)))
      metric = fn key -> ok |> Enum.map(& &1["metrics"][key]) |> Enum.filter(&is_number/1) end
      judged_ok = ok |> Enum.map(& &1["judge"]) |> Enum.filter(&is_map/1)

      %{
        id: id,
        model: c["model"],
        attempted: length(results),
        failed: length(results) - length(ok),
        judged: length(judged),
        wins: length(wins),
        wins_by_language: Enum.frequencies_by(wins, &languages[&1]),
        publishable: marked.("publishable"),
        gibberish: marked.("gibberish"),
        preachy: marked.("preachy"),
        broken_sentences: mean(Enum.map(judged_ok, & &1["broken"])),
        fluency: mean(Enum.map(judged_ok, & &1["fluency"])),
        disclaimers: mean(metric.("disclaimers")),
        mixed_words: mean(metric.("mixed_words")),
        foreign_chars: mean(metric.("foreign_chars")),
        hebrew_share: mean(metric.("hebrew_share")),
        words: mean(metric.("words")),
        mean_cost: mean(ok |> Enum.map(& &1["cost"]) |> Enum.filter(&is_number/1)),
        p50_ms: median(ok |> Enum.map(& &1["ms"]) |> Enum.filter(&is_number/1))
      }
    end)
  end

  @doc "The report as markdown."
  def report_markdown(manifest, votes) do
    rows = tally(manifest, votes)
    judged = rows |> List.first(%{judged: 0}) |> Map.get(:judged)

    """
    # Writing eval #{manifest["run_id"]}

    #{length(manifest["days"])} days, #{judged} judged. Baseline: #{@baseline}. `published` is
    the page readers actually got that day. Language columns come from the judge model
    (#{Judge.model()}); disclaimers, mixed-script words and Hebrew share are automatic.

    | Candidate | Wins | Wins he / en | Publishable | Gibberish | Preachy | Failed | Broken sentences | Fluency | Disclaimers | Mixed-script words | Hebrew share | Words | Cost per page | p50 |
    |---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
    """ <>
      (rows
       |> Enum.sort_by(&{-&1.wins, -&1.publishable})
       |> Enum.map_join("\n", fn r ->
         "| #{r.id} | #{r.wins} (#{pct(r.wins, r.judged)}) " <>
           "| #{Map.get(r.wins_by_language, "he", 0)} / #{Map.get(r.wins_by_language, "en", 0)} " <>
           "| #{r.publishable} | #{r.gibberish} | #{r.preachy} | #{r.failed}/#{r.attempted} " <>
           "| #{num(r.broken_sentences)} | #{num(r.fluency)} | #{num(r.disclaimers)} " <>
           "| #{num(r.mixed_words)} | #{num(r.hebrew_share)} | #{num(r.words, 0)} " <>
           "| #{usd(r.mean_cost)} | #{secs(r.p50_ms)} |"
       end)) <> "\n"
  end

  def load_manifest(run_dir) do
    path = Path.join(run_dir, "manifest.json")
    if File.exists?(path), do: path |> File.read!() |> Jason.decode!()
  end

  def save_manifest(run_dir, manifest) do
    File.write!(Path.join(run_dir, "manifest.json"), Jason.encode!(manifest, pretty: true))
  end

  defp mean([]), do: nil
  defp mean(xs), do: Enum.sum(xs) / length(xs)

  defp median([]), do: nil
  defp median(xs), do: xs |> Enum.sort() |> Enum.at(div(length(xs), 2))

  defp pct(_, 0), do: "-"
  defp pct(n, d), do: "#{round(100 * n / d)}%"

  defp num(x, decimals \\ 2)
  defp num(nil, _), do: "-"
  defp num(x, 0), do: "#{round(x)}"
  defp num(x, d), do: :erlang.float_to_binary(x * 1.0, decimals: d)

  defp usd(nil), do: "-"
  defp usd(x), do: "$" <> :erlang.float_to_binary(x * 1.0, decimals: 4)

  defp secs(nil), do: "-"
  defp secs(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
