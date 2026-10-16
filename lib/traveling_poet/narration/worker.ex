defmodule TravelingPoet.Narration.Worker do
  @moduledoc """
  Narrates a page when it is published. Sibling of the notifiers on
  "journal:published"; no-op unless `Narration.configured?/0`. A revision of
  a published page does not broadcast there, so the journal API calls
  `refresh_async/1` after the re-put instead.

  Off in test (`narration_auto: false`); tests call `Narration.generate/1`.
  """

  use GenServer
  require Logger

  alias TravelingPoet.{Journal, Narration}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if auto?() do
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "journal:published")
      {:ok, %{}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info({:journal_published, _poet_id, entry_id}, state) do
    refresh_async(entry_id)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Narrates the entry in a task, off whoever is calling. Nothing happens when the feature is off."
  def refresh_async(entry_id) when is_integer(entry_id) do
    if auto?() do
      Task.start(fn ->
        case Narration.generate(Journal.get_entry!(entry_id)) do
          {:ok, _} ->
            :ok

          {:skip, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("narration: entry #{entry_id} failed: #{inspect(reason)}")
        end
      end)
    end

    :ok
  end

  @doc """
  Reads the entry now because a reader asked, and tells the poet's topic
  how it went: `{:narration_ready, id}` from `Narration.generate/2`, or
  `{:narration_failed, id}` so the page can put its button back. Runs
  inline when `narration_inline` is set (tests), in a task otherwise.
  """
  def request(entry_id) when is_integer(entry_id) do
    run = fn ->
      entry = Journal.get_entry!(entry_id)

      failed = fn reason ->
        Logger.warning("narration: on-demand entry #{entry_id}: #{inspect(reason)}")

        Phoenix.PubSub.broadcast(
          TravelingPoet.PubSub,
          "poet:#{entry.poet_id}",
          {:narration_failed, entry_id}
        )
      end

      # A raise or exit inside (the bucket client raises on missing
      # credentials, for one) must reach the page too, or the ring breathes
      # forever; the page also gives up on its own after a while.
      try do
        case Narration.generate(entry, on_demand: true) do
          {:ok, _} -> :ok
          other -> failed.(other)
        end
      rescue
        e -> failed.({:raised, Exception.message(e)})
      catch
        :exit, reason -> failed.({:exit, reason})
      end
    end

    if Application.get_env(:traveling_poet, :narration_inline, false),
      do: run.(),
      else: Task.start(run)

    :ok
  end

  defp auto? do
    Narration.configured?() and Application.get_env(:traveling_poet, :narration_auto, true)
  end
end
