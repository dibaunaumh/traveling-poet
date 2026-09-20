defmodule TravelingPoet.Evals.Images do
  @moduledoc """
  Blind eval of image models against the drawings poets actually ask for.

  Driven by `mix tpoet.eval_images`, never by `mix test` or the request path:
  every run spends real money on OpenRouter.

  One run lives in `evals/images/<run_id>/`:

    * `manifest.json` - candidates, prompts, one result per prompt and
      candidate (file, cost, latency, error, pre-screen verdict) and the
      blind letter assignment
    * `raw/<prompt>/<candidate>.<ext>` - the images as the models returned them
    * `page/` - the judging page. Files there are named by letter only, so the
      page itself does not say which model drew what; the mapping stays in the
      manifest until `report/2` reveals it

  The prompt is the poet's stored prompt plus `Illustrations.style_suffix/1`,
  exactly what production sends. Every candidate, the baseline included, goes
  through OpenRouter's Image API so they are compared on one route; Gemini
  costs the same there as on chat completions.

  Generation is resumable: rerunning a run id keeps every image already made.
  """

  alias TravelingPoet.Illustrations
  alias TravelingPoet.Evals.{ImageJudge, ImagePage}

  @baseline "gemini-2.5-flash"

  # Prices are OpenRouter's Image API listing on 2026-09-18, per 1K image; the
  # report uses the cost OpenRouter returns, these are only for planning.
  @candidates [
    %{id: @baseline, model: "google/gemini-2.5-flash-image", params: %{}, list_usd: 0.039},
    %{
      id: "nano-banana-2-lite",
      model: "google/gemini-3.1-flash-lite-image",
      params: %{},
      list_usd: 0.034
    },
    %{
      id: "qwen-image-3",
      model: "qwen/qwen-image-3",
      params: %{resolution: "1K"},
      list_usd: 0.03
    },
    %{
      id: "flux2-klein-4b",
      model: "black-forest-labs/flux.2-klein-4b",
      params: %{aspect_ratio: "1:1"},
      list_usd: 0.014
    },
    %{
      id: "seedream-5-lite",
      model: "bytedance-seed/seedream-5-0-lite",
      params: %{},
      list_usd: 0.035
    },
    %{
      id: "mai-image-2.6-flash",
      model: "microsoft/mai-image-2.6-flash",
      params: %{},
      list_usd: 0.02
    }
  ]

  @letters ~w(A B C D E F G H I J)

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

  def prompts_path, do: Application.app_dir(:traveling_poet, "priv/evals/image_prompts.json")

  def load_prompts(path \\ prompts_path()) do
    path |> File.read!() |> Jason.decode!()
  end

  @doc """
  Generates every missing image, pre-screens every unscreened one, and writes
  the judging page. Returns the manifest.
  """
  def run(run_dir, prompts, candidates, opts \\ []) do
    File.mkdir_p!(run_dir)
    manifest = load_manifest(run_dir) || new_manifest(run_dir, prompts, candidates)
    log = Keyword.get(opts, :log, fn _ -> :ok end)

    manifest
    |> then(fn m -> if Keyword.get(opts, :rescreen, false), do: clear_screen(m), else: m end)
    |> generate(run_dir, prompts, candidates, log)
    |> then(fn m -> if Keyword.get(opts, :screen, true), do: screen(m, run_dir, log), else: m end)
    |> assign_blind(Keyword.get(opts, :seed, Path.basename(run_dir)))
    |> tap(&save_manifest(run_dir, &1))
    |> tap(&ImagePage.write(run_dir, &1))
  end

  defp new_manifest(run_dir, prompts, candidates) do
    %{
      "run_id" => Path.basename(run_dir),
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "candidates" => Enum.map(candidates, &stringify/1),
      "prompts" => prompts,
      "results" => [],
      "blind" => %{}
    }
  end

  defp generate(manifest, run_dir, prompts, candidates, log) do
    done =
      for %{"status" => "ok"} = r <- manifest["results"],
          into: MapSet.new(),
          do: {r["prompt_id"], r["candidate_id"]}

    todo =
      for p <- prompts, c <- candidates, not MapSet.member?(done, {p["id"], c.id}), do: {p, c}

    log.("generating #{length(todo)} images (#{MapSet.size(done)} already done)")

    fresh =
      todo
      |> Task.async_stream(fn {p, c} -> generate_one(run_dir, p, c, log) end,
        max_concurrency: 4,
        timeout: 240_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, result} -> [result]
        {:exit, _} -> []
      end)

    kept =
      Enum.reject(manifest["results"], &({&1["prompt_id"], &1["candidate_id"]} in keys(fresh)))

    manifest
    |> Map.put("results", kept ++ fresh)
    |> Map.put("candidates", merge_candidates(manifest["candidates"], candidates))
  end

  defp keys(results), do: Enum.map(results, &{&1["prompt_id"], &1["candidate_id"]})

  defp merge_candidates(existing, candidates) do
    ids = Enum.map(existing, & &1["id"])
    existing ++ (candidates |> Enum.reject(&(&1.id in ids)) |> Enum.map(&stringify/1))
  end

  defp generate_one(run_dir, prompt, candidate, log) do
    full_prompt = String.trim(prompt["prompt"]) <> Illustrations.style_suffix(prompt["kind"])

    base = %{"prompt_id" => prompt["id"], "candidate_id" => candidate.id}

    case Illustrations.request(full_prompt,
           model: candidate.model,
           endpoint: :images,
           params: candidate.params
         ) do
      {:ok, %{bytes: bytes, content_type: ct, cost: cost, ms: ms}} ->
        rel = Path.join(["raw", prompt["id"], "#{candidate.id}.#{ext(ct)}"])
        path = Path.join(run_dir, rel)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bytes)
        log.("  ok    #{prompt["id"]} / #{candidate.id} (#{ms}ms, $#{cost})")

        Map.merge(base, %{
          "status" => "ok",
          "file" => rel,
          "content_type" => ct,
          "cost" => cost,
          "ms" => ms
        })

      {:error, reason} ->
        log.("  error #{prompt["id"]} / #{candidate.id}: #{inspect(reason)}")
        Map.merge(base, %{"status" => "error", "error" => inspect(reason)})
    end
  end

  defp clear_screen(manifest) do
    Map.update!(manifest, "results", fn rs -> Enum.map(rs, &Map.delete(&1, "screen")) end)
  end

  defp screen(manifest, run_dir, log) do
    prompts = Map.new(manifest["prompts"], &{&1["id"], &1})
    pending = Enum.filter(manifest["results"], &(&1["status"] == "ok" and is_nil(&1["screen"])))
    log.("pre-screening #{length(pending)} images with #{ImageJudge.model()}")

    screened =
      pending
      |> Task.async_stream(
        fn r ->
          p = prompts[r["prompt_id"]]
          bytes = File.read!(Path.join(run_dir, r["file"]))

          case ImageJudge.screen(bytes, r["content_type"], p["prompt"], p["kind"]) do
            {:ok, verdict} ->
              {r, verdict}

            {:error, reason} ->
              log.("  screen failed #{r["prompt_id"]} / #{r["candidate_id"]}: #{inspect(reason)}")
              {r, nil}
          end
        end,
        max_concurrency: 4,
        timeout: 120_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {r, verdict}} when is_map(verdict) -> [{r, verdict}]
        _ -> []
      end)
      |> Map.new(fn {r, v} -> {{r["prompt_id"], r["candidate_id"]}, v} end)

    results =
      Enum.map(manifest["results"], fn r ->
        case screened[{r["prompt_id"], r["candidate_id"]}] do
          nil -> r
          verdict -> Map.put(r, "screen", verdict)
        end
      end)

    Map.put(manifest, "results", results)
  end

  @doc """
  Gives each prompt's candidates a letter in a shuffled order that depends
  only on the seed and the prompt, so reruns keep the letters a judge may
  already have voted on. Existing assignments are never reshuffled.
  """
  def assign_blind(manifest, seed) do
    ids = Enum.map(manifest["candidates"], & &1["id"])

    blind =
      Map.new(manifest["prompts"], fn p ->
        existing = get_in(manifest, ["blind", p["id"]]) || %{}
        assigned = Map.values(existing)
        new_ids = ids |> Enum.reject(&(&1 in assigned)) |> shuffle("#{seed}:#{p["id"]}")
        free = @letters -- Map.keys(existing)
        {p["id"], Map.merge(existing, Map.new(Enum.zip(free, new_ids)))}
      end)

    Map.put(manifest, "blind", blind)
  end

  defp shuffle(list, seed) do
    Enum.sort_by(list, &:crypto.hash(:sha256, seed <> ":" <> &1))
  end

  @doc """
  Reveals a judged run. `votes` is the page's export:
  `%{"votes" => %{prompt_id => %{"best" => letter, "publishable" => [letter]}}}`.

  Returns one row per candidate with the numbers the report prints.
  """
  def tally(manifest, votes) do
    by_prompt = votes["votes"] || %{}
    judged = Map.keys(by_prompt)
    blind = manifest["blind"]
    prompts = Map.new(manifest["prompts"], &{&1["id"], &1})

    Enum.map(manifest["candidates"], fn c ->
      id = c["id"]
      results = Enum.filter(manifest["results"], &(&1["candidate_id"] == id))
      ok = Enum.filter(results, &(&1["status"] == "ok"))
      screened = Enum.filter(ok, &is_map(&1["screen"]))
      costs = ok |> Enum.map(& &1["cost"]) |> Enum.filter(&is_number/1)

      letter_of = fn pid ->
        Enum.find_value(blind[pid] || %{}, fn {l, cid} -> cid == id && l end)
      end

      wins = Enum.count(judged, fn pid -> by_prompt[pid]["best"] == letter_of.(pid) end)

      publishable =
        Enum.count(judged, fn pid -> letter_of.(pid) in (by_prompt[pid]["publishable"] || []) end)

      wins_by_kind =
        judged
        |> Enum.filter(fn pid -> by_prompt[pid]["best"] == letter_of.(pid) end)
        |> Enum.frequencies_by(fn pid -> prompts[pid]["category"] end)

      %{
        id: id,
        model: c["model"],
        attempted: length(results),
        failed: length(results) - length(ok),
        screen_pass: Enum.count(screened, & &1["screen"]["pass"]),
        screened: length(screened),
        judged: length(judged),
        wins: wins,
        wins_by_category: wins_by_kind,
        publishable: publishable,
        mean_cost: mean(costs),
        total_cost: Enum.sum(costs),
        cost_per_publishable:
          if(publishable > 0 and costs != [],
            do: mean(costs) * length(judged) / publishable,
            else: nil
          ),
        p50_ms: median(Enum.map(ok, & &1["ms"]))
      }
    end)
  end

  @doc "The report as markdown."
  def report_markdown(manifest, votes) do
    rows = tally(manifest, votes)
    judged = rows |> List.first(%{judged: 0}) |> Map.get(:judged)

    header = """
    # Image eval #{manifest["run_id"]}

    #{length(manifest["prompts"])} prompts, #{judged} judged. Baseline: #{@baseline}.

    | Candidate | Wins | Publishable | Pre-screen pass | Failed | Mean cost | Cost per publishable | p50 latency |
    |---|---|---|---|---|---|---|---|
    """

    body =
      rows
      |> Enum.sort_by(&{-&1.wins, -&1.publishable})
      |> Enum.map_join("\n", fn r ->
        "| #{r.id} | #{r.wins} (#{pct(r.wins, r.judged)}) | #{r.publishable} (#{pct(r.publishable, r.judged)}) " <>
          "| #{r.screen_pass}/#{r.screened} | #{r.failed}/#{r.attempted} | #{usd(r.mean_cost)} " <>
          "| #{usd(r.cost_per_publishable)} | #{secs(r.p50_ms)} |"
      end)

    categories =
      manifest["prompts"] |> Enum.map(& &1["category"]) |> Enum.uniq()

    by_cat =
      "\n\n## Wins by category\n\n| Candidate | " <>
        Enum.join(categories, " | ") <>
        " |\n|---|" <>
        String.duplicate("---|", length(categories)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn r ->
          "| #{r.id} | " <>
            Enum.map_join(categories, " | ", &to_string(Map.get(r.wins_by_category, &1, 0))) <>
            " |"
        end)

    header <> body <> by_cat <> "\n"
  end

  def load_manifest(run_dir) do
    path = Path.join(run_dir, "manifest.json")
    if File.exists?(path), do: path |> File.read!() |> Jason.decode!()
  end

  def save_manifest(run_dir, manifest) do
    File.write!(Path.join(run_dir, "manifest.json"), Jason.encode!(manifest, pretty: true))
  end

  defp stringify(c) do
    %{
      "id" => c.id,
      "model" => c.model,
      "params" => Map.new(c.params, fn {k, v} -> {to_string(k), v} end)
    }
  end

  defp ext("image/jpeg"), do: "jpg"
  defp ext("image/webp"), do: "webp"
  defp ext(_), do: "png"

  defp mean([]), do: nil
  defp mean(xs), do: Enum.sum(xs) / length(xs)

  defp median([]), do: nil

  defp median(xs) do
    sorted = Enum.sort(xs)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp pct(_, 0), do: "-"
  defp pct(n, d), do: "#{round(100 * n / d)}%"

  defp usd(nil), do: "-"
  defp usd(x), do: "$" <> :erlang.float_to_binary(x * 1.0, decimals: 4)

  defp secs(nil), do: "-"
  defp secs(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
