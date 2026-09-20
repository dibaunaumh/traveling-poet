defmodule Mix.Tasks.Tpoet.EvalImages do
  @shortdoc "Blind eval of image models on real poet prompts (spends real money)"

  @moduledoc """
  Generates every candidate's drawing for the prompts in
  `priv/evals/image_prompts.json`, pre-screens them with a vision model, and
  writes a blind judging page. See `TravelingPoet.Evals.Images`.

      mix tpoet.eval_images                          # all candidates, all prompts
      mix tpoet.eval_images --limit 2                # first 2 prompts (a smoke run)
      mix tpoet.eval_images --models gemini-2.5-flash,flux2-klein-4b
      mix tpoet.eval_images --run 2026-09-18         # resume or extend a run
      mix tpoet.eval_images --no-screen              # skip the vision pre-screen
      mix tpoet.eval_images --run <run> --rescreen   # redo the pre-screen only
      mix tpoet.eval_images --list                   # candidates and list prices

      mix tpoet.eval_images --report evals/images/<run> --votes votes.json

  Output goes to `evals/images/<run>/` (gitignored). Open `page/index.html`,
  judge, press "Export votes", then run the `--report` form.

  Needs OPENROUTER_API_KEY. EVAL_JUDGE_MODEL picks the pre-screen model.
  Does not start the app: no Repo, no schedulers, no Telegram poller.
  """

  use Mix.Task

  alias TravelingPoet.Evals.Images

  @switches [
    limit: :integer,
    models: :string,
    run: :string,
    screen: :boolean,
    rescreen: :boolean,
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
    for c <- Images.candidates() do
      IO.puts(
        "#{String.pad_trailing(c.id, 22)} #{String.pad_trailing(c.model, 40)} ~$#{c.list_usd}"
      )
    end
  end

  defp generate(opts) do
    if Application.get_env(:traveling_poet, :openrouter_api_key) in [nil, ""] do
      Mix.raise("OPENROUTER_API_KEY is not set")
    end

    candidates = Images.candidates(opts[:models] && String.split(opts[:models], ","))
    prompts = Images.load_prompts()
    prompts = if opts[:limit], do: Enum.take(prompts, opts[:limit]), else: prompts
    run_id = opts[:run] || Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M")
    run_dir = Path.join(["evals", "images", run_id])

    estimate = Enum.sum(Enum.map(candidates, & &1.list_usd)) * length(prompts)

    IO.puts(
      "== #{length(prompts)} prompts x #{length(candidates)} candidates " <>
        "(about $#{Float.round(estimate, 2)} before the pre-screen) -> #{run_dir}"
    )

    manifest =
      Images.run(run_dir, prompts, candidates,
        screen: Keyword.get(opts, :screen, true),
        rescreen: Keyword.get(opts, :rescreen, false),
        log: &IO.puts/1
      )

    spent =
      manifest["results"] |> Enum.map(& &1["cost"]) |> Enum.filter(&is_number/1) |> Enum.sum()

    failed = Enum.count(manifest["results"], &(&1["status"] == "error"))

    IO.puts("""

    == Done. Image spend so far in this run: $#{Float.round(spent * 1.0, 3)}; #{failed} failed.
    Judge:  open #{Path.join(run_dir, "page/index.html")}
    Reveal: mix tpoet.eval_images --report #{run_dir} --votes <exported votes.json>
    """)
  end

  defp report(run_dir, nil), do: report(run_dir, Path.join(run_dir, "votes.json"))

  defp report(run_dir, votes_path) do
    manifest = Images.load_manifest(run_dir) || Mix.raise("no manifest.json in #{run_dir}")
    votes = votes_path |> File.read!() |> Jason.decode!()

    if votes["run_id"] && votes["run_id"] != manifest["run_id"] do
      Mix.raise("votes are for run #{votes["run_id"]}, not #{manifest["run_id"]}")
    end

    md = Images.report_markdown(manifest, votes)
    File.write!(Path.join(run_dir, "report.md"), md)
    IO.puts(md)
    IO.puts("(written to #{Path.join(run_dir, "report.md")})")
  end
end
