defmodule TravelingPoet.Evals.Search do
  @moduledoc """
  Stage A of the search eval (issue #75): replays real poet queries against
  each search backend and scores what comes back.

  Driven by `mix tpoet.eval_search`, never by `mix test` or the request path.
  Every run spends real money (Sonar on OpenRouter, Tavily credits, the
  judge).

  This isolates search quality from agent variance: the same query goes to
  every provider. It cannot show what a provider does to a whole daily run
  (Tavily returns raw hits, so the poet may fetch more pages and spend more
  model tokens); stage B, the end-to-end runs, measures that.

  A run lives in `evals/search/<run_id>/results.json`, one entry per query
  and provider: the raw result, how many of its URLs are alive
  (`LinkCheck.check/1`), and the judge's scores. Reruns fill in only what is
  missing.
  """

  alias TravelingPoet.Evals.Search.{Judge, Providers}
  alias TravelingPoet.LinkCheck

  @max_links 8

  def queries_path, do: Application.app_dir(:traveling_poet, "priv/evals/search_queries.json")

  def load_queries(path \\ queries_path()), do: path |> File.read!() |> Jason.decode!()

  def run(run_dir, queries, providers, opts \\ []) do
    File.mkdir_p!(run_dir)
    log = Keyword.get(opts, :log, fn _ -> :ok end)
    path = Path.join(run_dir, "results.json")

    existing =
      if File.exists?(path), do: path |> File.read!() |> Jason.decode!(), else: %{"results" => []}

    have =
      for %{"status" => "ok", "score" => s} = r <- existing["results"],
          is_map(s),
          into: MapSet.new(),
          do: {r["query_id"], r["provider"]}

    todo =
      for q <- queries,
          p <- providers,
          not MapSet.member?(have, {q["id"], to_string(p)}),
          do: {q, p}

    log.("#{length(todo)} searches to run (#{MapSet.size(have)} already scored)")

    fresh =
      todo
      |> Task.async_stream(fn {q, p} -> one(q, p, log) end,
        max_concurrency: 4,
        timeout: 300_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, r} -> [r]
        {:exit, _} -> []
      end)

    fresh_keys = MapSet.new(fresh, &{&1["query_id"], &1["provider"]})

    kept =
      Enum.reject(
        existing["results"],
        &MapSet.member?(fresh_keys, {&1["query_id"], &1["provider"]})
      )

    results = %{
      "run_id" => Path.basename(run_dir),
      "queries" => queries,
      "results" => kept ++ fresh
    }

    File.write!(path, Jason.encode!(results, pretty: true))
    results
  end

  defp one(query, provider, log) do
    base = %{"query_id" => query["id"], "provider" => to_string(provider)}

    case Providers.search(provider, query) do
      {:ok, res} ->
        res = res |> Jason.encode!() |> Jason.decode!()
        links = check_links(res["urls"])

        score =
          case Judge.score(query, res) do
            {:ok, s} ->
              s

            {:error, reason} ->
              log.("  judge failed #{query["id"]} / #{provider}: #{inspect(reason)}")
              nil
          end

        log.("  ok    #{query["id"]} / #{provider} (#{res["ms"]}ms, #{length(res["urls"])} urls)")

        Map.merge(base, %{
          "status" => "ok",
          "result" => res,
          "links" => links,
          "score" => score
        })

      {:error, reason} ->
        log.("  error #{query["id"]} / #{provider}: #{inspect(reason)}")
        Map.merge(base, %{"status" => "error", "error" => inspect(reason)})
    end
  end

  defp check_links(urls) do
    checked = urls |> Enum.uniq() |> Enum.take(@max_links)

    alive =
      checked
      |> Task.async_stream(&(LinkCheck.check(&1) == :ok), timeout: 30_000, on_timeout: :kill_task)
      |> Enum.count(&match?({:ok, true}, &1))

    %{"checked" => length(checked), "alive" => alive}
  end

  @doc "One summary row per provider."
  def summarize(%{"results" => results}) do
    results
    |> Enum.group_by(& &1["provider"])
    |> Enum.sort_by(fn {p, _} -> Enum.find_index(Providers.all(), &(to_string(&1) == p)) end)
    |> Enum.map(fn {provider, rs} ->
      ok = Enum.filter(rs, &(&1["status"] == "ok"))
      scored = Enum.filter(ok, &is_map(&1["score"]))
      costs = ok |> Enum.map(&get_in(&1, ["result", "cost"])) |> Enum.filter(&is_number/1)
      facts = Enum.map(scored, & &1["score"]["specific_facts"])
      checked = ok |> Enum.map(& &1["links"]["checked"]) |> Enum.sum()
      alive = ok |> Enum.map(& &1["links"]["alive"]) |> Enum.sum()

      %{
        provider: provider,
        runs: length(rs),
        errors: length(rs) - length(ok),
        answers: mean(Enum.map(scored, & &1["score"]["answers"])),
        facts: mean(facts),
        sourced: mean(field(scored, "sourced")),
        current: mean(field(scored, "current")),
        right_urls: mean(field(scored, "right_urls")),
        suspect: Enum.count(scored, &(&1["score"]["suspect"] != [])),
        links_alive: if(checked > 0, do: alive / checked),
        urls: mean(Enum.map(ok, &length(&1["result"]["urls"]))),
        mean_cost: mean(costs),
        cost_per_fact:
          if(facts != [] and Enum.sum(facts) > 0,
            do: Enum.sum(costs) / Enum.sum(facts)
          ),
        p50_ms: median(Enum.map(ok, & &1["result"]["ms"]))
      }
    end)
  end

  defp field(scored, key),
    do: scored |> Enum.map(& &1["score"][key]) |> Enum.filter(&is_number/1)

  def report_markdown(%{"queries" => queries, "results" => results} = run) do
    rows = summarize(run)

    summary =
      """
      # Search replay #{run["run_id"]}

      #{length(queries)} real poet queries, each sent to every provider as OpenClaw sends it.
      Scores are 1-5 from a blind judge (#{Judge.model()}); facts = specific, checkable facts that answer the query.

      | Provider | Answers | Facts | Sourced | Current | Right URLs | Suspect | Links alive | URLs | Mean cost | Cost per fact | p50 |
      |---|---|---|---|---|---|---|---|---|---|---|---|
      """ <>
        Enum.map_join(rows, "\n", fn r ->
          "| #{r.provider} | #{f1(r.answers)} | #{f1(r.facts)} | #{f1(r.sourced)} | #{f1(r.current)} " <>
            "| #{f1(r.right_urls)} | #{r.suspect} | #{pct(r.links_alive)} | #{f1(r.urls)} " <>
            "| #{usd(r.mean_cost)} | #{usd(r.cost_per_fact)} | #{secs(r.p50_ms)} |"
        end)

    providers = Enum.map(rows, & &1.provider)
    by_key = Map.new(results, &{{&1["query_id"], &1["provider"]}, &1})

    per_query =
      "\n\n## Per query (answers / facts)\n\n| Query | " <>
        Enum.join(providers, " | ") <>
        " |\n|---|" <>
        String.duplicate("---|", length(providers)) <>
        "\n" <>
        Enum.map_join(queries, "\n", fn q ->
          "| #{q["id"]} #{q["query"] |> String.replace("|", "/") |> String.slice(0, 70)} | " <>
            Enum.map_join(providers, " | ", fn p ->
              case by_key[{q["id"], p}] do
                %{"score" => %{"answers" => a, "specific_facts" => f}} -> "#{a} / #{f}"
                %{"status" => "error"} -> "error"
                _ -> "-"
              end
            end) <> " |"
        end)

    summary <> per_query <> "\n"
  end

  defp mean([]), do: nil
  defp mean(xs), do: Enum.sum(xs) / length(xs)

  defp median([]), do: nil
  defp median(xs), do: xs |> Enum.sort() |> Enum.at(div(length(xs), 2))

  defp f1(nil), do: "-"
  defp f1(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1)

  defp pct(nil), do: "-"
  defp pct(x), do: "#{round(x * 100)}%"

  defp usd(nil), do: "-"
  defp usd(x), do: "$" <> :erlang.float_to_binary(x * 1.0, decimals: 4)

  defp secs(nil), do: "-"
  defp secs(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
