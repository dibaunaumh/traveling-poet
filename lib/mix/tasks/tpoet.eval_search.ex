defmodule Mix.Tasks.Tpoet.EvalSearch do
  @shortdoc "Search provider eval: replay real poet queries (spends real money)"

  @moduledoc """
  Stage A of the search eval (issue #75). See `TravelingPoet.Evals.Search`.

      mix tpoet.eval_search collect SPRITE...        # web_search calls from fleet transcripts
      mix tpoet.eval_search replay                   # every query in priv/evals/search_queries.json
      mix tpoet.eval_search replay --limit 5 --providers sonar_pro,tavily_basic
      mix tpoet.eval_search replay --run 2026-09-18  # resume or extend a run
      mix tpoet.eval_search report evals/search/<run>

  Providers: sonar_pro (the fleet today), sonar, tavily_basic, tavily_advanced.
  Needs OPENROUTER_API_KEY, and TAVILY_API_KEY for the Tavily providers.
  `collect` also needs SPRITES_TOKEN; it only reads, but wakes each sprite.
  Output goes to `evals/search/` (gitignored). Does not start the app.
  """

  use Mix.Task

  alias TravelingPoet.Evals.Search
  alias TravelingPoet.Evals.Search.{Providers, Queries}

  @switches [limit: :integer, providers: :string, run: :string, per_sprite: :integer]

  @impl true
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)

    case rest do
      ["collect" | sprites] when sprites != [] -> collect(sprites, opts)
      ["replay"] -> replay(opts)
      ["report", run_dir] -> report(run_dir)
      _ -> Mix.raise("usage: see `mix help tpoet.eval_search`")
    end
  end

  defp collect(sprites, opts) do
    %{calls: calls, errors: errors} = Queries.collect(sprites)
    for {s, reason} <- errors, do: IO.puts("!! #{s}: #{reason}")

    File.mkdir_p!("evals/search")
    File.write!("evals/search/calls.json", Jason.encode!(calls, pretty: true))

    sessions = Queries.per_session(calls)
    searches = Enum.map(sessions, & &1.searches)
    sample = Queries.sample(calls, opts[:per_sprite] || 4)
    File.write!("evals/search/sample.json", Jason.encode!(sample, pretty: true))

    IO.puts("""
    == #{Enum.count(calls, &(&1.tool == "web_search"))} searches, #{Enum.count(calls, &(&1.tool == "web_fetch"))} fetches in #{length(sessions)} sessions
       searches per session: median #{median(searches)}, max #{Enum.max(searches, fn -> 0 end)}
       all calls: evals/search/calls.json
       a replay sample (#{length(sample)} queries): evals/search/sample.json
       Curate it into priv/evals/search_queries.json; check it for anything personal first.
    """)
  end

  defp replay(opts) do
    providers = if opts[:providers], do: Providers.parse!(opts[:providers]), else: Providers.all()

    case Enum.reject(providers, &Providers.configured?/1) do
      [] ->
        :ok

      missing ->
        Mix.raise("no key for #{Enum.join(missing, ", ")} (OPENROUTER_API_KEY / TAVILY_API_KEY)")
    end

    queries = Search.load_queries()
    queries = if opts[:limit], do: Enum.take(queries, opts[:limit]), else: queries
    run_id = opts[:run] || Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M")
    run_dir = Path.join(["evals", "search", run_id])

    IO.puts("== #{length(queries)} queries x #{length(providers)} providers -> #{run_dir}")
    results = Search.run(run_dir, queries, providers, log: &IO.puts/1)
    write_report(run_dir, results)
  end

  defp report(run_dir) do
    results = Path.join(run_dir, "results.json") |> File.read!() |> Jason.decode!()
    write_report(run_dir, results)
  end

  defp write_report(run_dir, results) do
    md = Search.report_markdown(results)
    File.write!(Path.join(run_dir, "report.md"), md)
    IO.puts(md)
    IO.puts("(written to #{Path.join(run_dir, "report.md")})")
  end

  defp median([]), do: 0
  defp median(xs), do: xs |> Enum.sort() |> Enum.at(div(length(xs), 2))
end
