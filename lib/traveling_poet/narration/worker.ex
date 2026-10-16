defmodule TravelingPoet.Narration.Worker do
  @moduledoc """
  Runs a reading off the LiveView that asked for it. Nothing reads a page on
  its own (dec-004, 2026-10-16: on demand only): a press on the ring is the
  one way a recording comes to exist, and a revision of a published page
  only drops a recording that no longer matches the words.

  Both run in a `Task` so the caller (a LiveView, the agent API) never waits
  on the speech call or the bucket; `narration_inline` (test.exs) runs them
  in the caller instead, inside the test's sandbox connection.
  """

  require Logger

  alias TravelingPoet.{Journal, Narration}

  @doc """
  Reads the entry now because a reader asked, and tells the poet's topic
  how it went: `{:narration_ready, id}` from `Narration.generate/2`, or
  `{:narration_failed, id}` so the page can put its ring back.
  """
  def request(entry_id) when is_integer(entry_id) do
    run(fn ->
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
        case Narration.generate(entry) do
          {:ok, _} -> :ok
          other -> failed.(other)
        end
      rescue
        e -> failed.({:raised, Exception.message(e)})
      catch
        :exit, reason -> failed.({:exit, reason})
      end
    end)
  end

  @doc "A published page was re-put: a recording of the old words goes (`Narration.drop_stale/1`)."
  def revised(entry_id) when is_integer(entry_id) do
    if Narration.configured?() do
      run(fn ->
        case Narration.drop_stale(entry_id) do
          :dropped -> Logger.info("narration: entry #{entry_id} revised, recording dropped")
          _ -> :ok
        end
      end)
    end

    :ok
  end

  defp run(fun) do
    if Application.get_env(:traveling_poet, :narration_inline, false),
      do: fun.(),
      else: Task.start(fun)

    :ok
  end
end
