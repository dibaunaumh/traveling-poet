defmodule TravelingPoet.Books.Pdf.SpriteRunner do
  @moduledoc """
  Runs a book render on the poet's sprite, through `SpritesClient.exec` only:
  no agent, no model, nothing the companion's chat can steer.

  The render script (`priv/book_render/render-book.mjs`) and its job file are
  written fresh before every run, so a script changed on the sprite between
  runs is never the one that runs. The script is started detached (an exec
  call must return within two minutes; a render and a first-time install can
  take longer) and reports through `status.json`, which `status/2` reads.
  """

  @script_path "priv/book_render/render-book.mjs"
  @external_resource @script_path
  @script File.read!(@script_path)

  @doc "The script as the app ships it."
  def script, do: @script

  def work_dir(pdf_id), do: ".tpoet/render/#{pdf_id}"

  @doc "Writes the script and job, starts the render detached. Returns at once."
  def start(sprite_name, pdf_id, job) when is_map(job) do
    dir = "$HOME/#{work_dir(pdf_id)}"
    job = Map.put(job, :work_dir, work_dir(pdf_id))

    cmd =
      "mkdir -p #{dir} && cd #{dir} && rm -f status.json && " <>
        "echo #{Base.encode64(@script)} | base64 -d > render-book.mjs && " <>
        "echo #{Base.encode64(Jason.encode!(job))} | base64 -d > job.json && " <>
        "(setsid nohup node render-book.mjs job.json > render.log 2>&1 < /dev/null &) && " <>
        "echo started"

    case client().exec(sprite_name, cmd) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The render's status: `{:ok, %{\"state\" => ...}}`, or `{:ok, nil}` before it reports."
  def status(sprite_name, pdf_id) do
    case client().exec(
           sprite_name,
           "cat $HOME/#{work_dir(pdf_id)}/status.json 2>/dev/null || true"
         ) do
      {:ok, out} ->
        case out |> clean() |> String.trim() |> Jason.decode() do
          {:ok, %{} = status} -> {:ok, status}
          _ -> {:ok, nil}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The last lines of the render log, package-manager chatter left out."
  def log_tail(sprite_name, pdf_id) do
    cmd =
      "grep -v -E '^(Setting up|Unpacking|Selecting|Preparing|Get:|Processing|Reading database|\\(Reading)' " <>
        "$HOME/#{work_dir(pdf_id)}/render.log 2>/dev/null | tail -c 6000 || true"

    case client().exec(sprite_name, cmd) do
      {:ok, out} -> clean(out)
      _ -> ""
    end
  end

  @doc "Removes the run's directory. Headless Chrome stays installed for next time."
  def cleanup(sprite_name, pdf_id) do
    client().exec(sprite_name, "rm -rf $HOME/#{work_dir(pdf_id)}")
    :ok
  end

  # exec output carries stream-frame bytes around the text
  defp clean(out) when is_binary(out), do: String.replace(out, ~r/[\x00-\x08\x0b-\x1f]/, "")
  defp clean(_), do: ""

  defp client,
    do: Application.get_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClient)
end
