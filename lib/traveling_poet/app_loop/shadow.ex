defmodule TravelingPoet.AppLoop.Shadow do
  @moduledoc """
  The shadow run of option D (dec-024): after a sprite poet publishes its
  day, the app-side loop (`AppLoop.Runner`) writes the same day from the
  same start, and nothing it writes reaches the reader.

  "The same start" is read off the sprite, from the run that published:
  the trigger the app sent, the `get_poet_context` answer the poet got, and
  the workspace files it wrote under (`Evals.Writing.Days.read_sprite/1`).
  Research is live (`AppLoop.Web`), so the loop finds its own pages, as a
  real run would. Every write lands in an `AppLoop.Draft`; reads go to the
  real endpoints, in-process.

  Switched on per poet with `settings["app_loop"] = "shadow"`, the same way
  a poet's model is switched. Each run is one `app_loop_runs` row, which
  the grading reads next to the page the sprite published.

      # on prod, over rpc
      Shadow.run(poet_id, ~D[2026-11-18])
  """

  require Logger

  import Ecto.Query

  alias TravelingPoet.AppLoop.{Draft, Run, Runner}
  alias TravelingPoet.Evals.Writing
  alias TravelingPoet.Evals.Writing.Days
  alias TravelingPoet.{Journal, Poets, Provisioner, Repo}

  @skill "skills/travel-and-journal/SKILL.md"
  @system_files ~w(instructions.md AGENTS.md IDENTITY.md USER.md) ++ [@skill]

  def enabled?(poet), do: get_in(poet.settings || %{}, ["app_loop"]) == "shadow"

  @doc """
  Called by `DailyJourneyScheduler` once a day is published. Starts the
  shadow run for a poet in shadow mode, in the background: the daily run
  never waits on it.
  """
  def after_publish(_user, poet) do
    if enabled?(poet) do
      case Journal.latest_published_entry(poet.id) do
        nil -> :ok
        entry -> Task.start(fn -> run(poet.id, entry.entry_date) end)
      end
    end

    :ok
  end

  @doc "Runs the shadow for one poet and day, and stores the run."
  def run(poet_id, date, opts \\ []) when is_integer(poet_id) do
    poet = Poets.Poet |> Repo.get!(poet_id) |> Repo.preload(:user)

    case inputs_for(poet, date, opts) do
      {:ok, inputs} ->
        result = Runner.run(inputs, Keyword.put(opts, :shadow, true))
        Logger.info("AppLoop.Shadow: poet #{poet.id} #{date} #{result.status}")
        save(poet, date, inputs, result)

      {:error, reason} ->
        Logger.warning("AppLoop.Shadow: poet #{poet.id} #{date} no input: #{inspect(reason)}")

        %Run{}
        |> Run.changeset(%{
          poet_id: poet.id,
          entry_date: date,
          status: "no_input",
          error: inspect(reason)
        })
        |> Repo.insert()
    end
  end

  @doc """
  What the loop starts from, read off the sprite: `{:ok, inputs}` or
  `{:error, reason}`. `sprite_run:` hands it in instead (tests).
  """
  def inputs_for(poet, date, opts \\ []) do
    with {:ok, %{"runs" => runs, "files" => files}} <- sprite_runs(poet, opts),
         %{} = run <- published_run(runs, date) || {:error, :no_published_run},
         context when is_binary(context) <- context_of(run) || {:error, :no_context} do
      {:ok,
       %{
         user: poet.user,
         poet: poet,
         model: Provisioner.poet_model(poet),
         system: Writing.system_prompt(files, only: @system_files),
         trigger: run["prompt"],
         entry_date: date,
         context: context,
         day: day_of(context),
         files: Map.merge(seeded_skills(), files)
       }}
    end
  end

  # The sprite's own copy wins; the other skills a poet may open (the poem
  # skill, say) come from what every sprite is seeded with.
  defp seeded_skills do
    Map.new(Provisioner.skill_files(), fn {path, text} -> {"skills/" <> path, text} end)
  end

  defp sprite_runs(poet, opts) do
    case Keyword.fetch(opts, :sprite_run) do
      {:ok, data} ->
        {:ok, data}

      :error ->
        user = poet.user
        Days.read_sprite(user.sprite_name || Provisioner.default_sprite_name(user.id))
    end
  end

  # The daily run that wrote this date; the last one when a retry did.
  defp published_run(runs, date) do
    runs
    |> Enum.filter(fn r ->
      String.starts_with?(r["prompt"] || "", "/travel-and-journal") and
        r["entry_date"] == Date.to_iso8601(date)
    end)
    |> List.last()
  end

  defp context_of(run) do
    Enum.find_value(run["results"] || [], fn r ->
      r["tool"] == "get_poet_context" && r["text"]
    end)
  end

  defp day_of(context) do
    case Jason.decode(context) do
      {:ok, %{"result" => %{"travel" => %{"day" => day}}}} -> day
      {:ok, %{"travel" => %{"day" => day}}} -> day
      _ -> nil
    end
  end

  defp save(poet, date, inputs, result) do
    %Run{}
    |> Run.changeset(%{
      poet_id: poet.id,
      entry_date: date,
      model: inputs.model,
      status: result.status,
      error: result.error && to_string(result.error),
      page: page(result.draft),
      steps: %{"items" => result.steps},
      model_calls: result.model_calls,
      tool_calls: result.tool_calls,
      malformed_calls: result.malformed_calls,
      tool_errors: result.tool_errors,
      tokens_in: result.tokens_in,
      tokens_out: result.tokens_out,
      cost: result.cost * 1.0,
      ms: result.ms,
      final_text: result.final_text,
      trigger: inputs.trigger
    })
    |> Repo.insert()
  end

  defp page(%Draft{} = d) do
    entry = d.entry || %{}

    %{
      "title" => entry["title"],
      "teaser" => entry["teaser"],
      "entry" => entry,
      "sections" => d.sections,
      "places" => d.places,
      "finds" => d.finds,
      "quiz" => d.quiz,
      "stay_areas" => d.stay_areas,
      "media" => d.media,
      "actions" => d.actions,
      "published" => Draft.published?(d)
    }
  end

  @doc "A poet's shadow runs, newest first."
  def runs(poet_id) do
    Repo.all(
      from r in Run, where: r.poet_id == ^poet_id, order_by: [desc: r.entry_date, desc: r.id]
    )
  end
end
