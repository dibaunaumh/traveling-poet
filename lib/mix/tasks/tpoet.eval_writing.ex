defmodule Mix.Tasks.Tpoet.EvalWriting do
  @shortdoc "Blind eval of text models writing real poet days (spends real money)"

  @moduledoc """
  Has every candidate write the page for each frozen day, checks and judges
  the language, and writes a blind judging page. See
  `TravelingPoet.Evals.Writing`.

  The days come from production first (they need the Repo and the sprites):

      fly ssh console -c fly.dev.toml -C "/app/bin/traveling_poet rpc 'TravelingPoet.Evals.Writing.Days.extract()'"
      # then fetch /tmp/writing_days.json into evals/writing/days.json

  Then, locally:

      mix tpoet.eval_writing                          # all candidates, all days
      mix tpoet.eval_writing --limit 1                # first day only (a smoke run)
      mix tpoet.eval_writing --models deepseek-v4-flash,glm-5.3
      mix tpoet.eval_writing --run 2026-11-10         # resume or extend a run
      mix tpoet.eval_writing --no-judge               # skip the language judge
      mix tpoet.eval_writing --days other_days.json
      mix tpoet.eval_writing --list                   # candidates and list prices

      mix tpoet.eval_writing --report evals/writing/<run> --votes votes.json

  Output goes to `evals/writing/<run>/` (gitignored, like the days file).
  Open `page/index.html`, judge, press "Export votes", then run the
  `--report` form.

  Needs OPENROUTER_API_KEY. EVAL_JUDGE_MODEL picks the language judge.
  Does not start the app: no Repo, no schedulers, no Telegram poller.
  """

  use Mix.Task

  alias TravelingPoet.Evals.Writing

  @switches [
    limit: :integer,
    models: :string,
    run: :string,
    days: :string,
    judge: :boolean,
    list: :boolean,
    report: :string,
    votes: :string
  ]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)

    cond do
      opts[:list] -> list()
      opts[:report] -> report(opts[:report], opts[:votes])
      true -> generate(opts)
    end
  end

  defp list do
    for %{id: id, model: model, list: {i, o}} <- Writing.candidates() do
      IO.puts(
        "#{String.pad_trailing(id, 22)} #{String.pad_trailing(model, 38)} $#{i} / $#{o} per Mtok"
      )
    end
  end

  defp generate(opts) do
    if Application.get_env(:traveling_poet, :openrouter_api_key) in [nil, ""] do
      Mix.raise("OPENROUTER_API_KEY is not set")
    end

    days_path = opts[:days] || Path.join(["evals", "writing", "days.json"])

    File.exists?(days_path) ||
      Mix.raise("no days file at #{days_path}; extract it on production first")

    candidates = Writing.candidates(opts[:models] && String.split(opts[:models], ","))
    days = Writing.load_days(days_path)
    days = if opts[:limit], do: Enum.take(days, opts[:limit]), else: days
    run_id = opts[:run] || Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M")
    run_dir = Path.join(["evals", "writing", run_id])

    IO.puts("== #{length(days)} days x #{length(candidates)} candidates -> #{run_dir}")

    manifest =
      Writing.run(run_dir, days, candidates,
        judge: Keyword.get(opts, :judge, true),
        log: &IO.puts/1
      )

    spent =
      manifest["results"] |> Enum.map(& &1["cost"]) |> Enum.filter(&is_number/1) |> Enum.sum()

    failed = Enum.count(manifest["results"], &(&1["status"] != "ok"))

    IO.puts("""

    == Done. Writing spend so far in this run: $#{Float.round(spent * 1.0, 3)}; #{failed} failed.
    Judge:  open #{Path.join(run_dir, "page/index.html")}
    Reveal: mix tpoet.eval_writing --report #{run_dir} --votes <exported votes.json>
    """)
  end

  defp report(run_dir, nil), do: report(run_dir, Path.join(run_dir, "votes.json"))

  defp report(run_dir, votes_path) do
    manifest = Writing.load_manifest(run_dir) || Mix.raise("no manifest.json in #{run_dir}")
    votes = votes_path |> File.read!() |> Jason.decode!()

    if votes["run_id"] && votes["run_id"] != manifest["run_id"] do
      Mix.raise("votes are for run #{votes["run_id"]}, not #{manifest["run_id"]}")
    end

    md = Writing.report_markdown(manifest, votes)
    File.write!(Path.join(run_dir, "report.md"), md)
    IO.puts(md)
    IO.puts("(written to #{Path.join(run_dir, "report.md")})")
  end
end
