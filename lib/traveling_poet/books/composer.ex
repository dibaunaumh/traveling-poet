defmodule TravelingPoet.Books.Composer do
  @moduledoc """
  Runs the poet's `/compose-book` turn and settles the edition by what
  landed.

  The same accounting rule as the daily run: the outcome is what reached the
  book, not what the agent said. A turn can narrate a lovely foreword in
  chat and never call `book_put_matter`; that edition failed and is
  refunded. A turn that wrote its matter and then dropped the socket
  succeeded, and is kept.
  """

  require Logger

  alias TravelingPoet.{AgentSession, Books, Credits, Repo, Usage}
  alias TravelingPoet.Books.{Edition, Matter}

  @trigger "/compose-book"
  # Reading a whole journey and writing an opener per stay is a long turn.
  @reply_timeout_ms 15 * 60 * 1000

  def trigger, do: @trigger

  @doc "Fires the turn in a task; `finish/2` settles the edition when it ends."
  def dispatch(user, %Edition{id: id}) do
    Task.start(fn ->
      Logger.info("Books.Composer: firing #{@trigger} for user #{user.id}, edition #{id}")

      outcome =
        AgentSession.run(user, @trigger, channel: "system", reply_timeout_ms: @reply_timeout_ms)

      finish(id, outcome)
    end)
  end

  @doc """
  Settles an open edition: `ready` when the poet's words landed, otherwise
  `failed` and refunded. An edition already settled is returned unchanged,
  so a late finish and the stale reaper cannot both act on it.
  """
  def finish(edition_id, outcome) do
    case Repo.get(Edition, edition_id) do
      %Edition{status: "composing"} = edition -> settle(edition, outcome)
      other -> other
    end
  end

  defp settle(edition, outcome) do
    user = Books.user_for(edition)

    if Matter.landed?(edition.matter) do
      log_landed(edition, outcome)

      if user,
        do: Usage.record(user.id, "book_compose", %{metadata: %{"edition_id" => edition.id}})

      edition =
        Books.settle(edition, %{
          status: "ready",
          composed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          error: nil
        })

      if user do
        Phoenix.PubSub.broadcast(
          TravelingPoet.PubSub,
          "books",
          {:book_ready, user.id, edition.id}
        )
      end

      edition
    else
      Logger.warning(
        "Books.Composer: edition #{edition.id} wrote no matter (#{describe(outcome)}), refunding"
      )

      if user, do: Credits.refund_book_compose(user, edition.id)

      Books.settle(edition, %{status: "failed", error: describe(outcome)})
    end
  end

  defp log_landed(_edition, {:ok, _reply}), do: :ok

  defp log_landed(edition, outcome) do
    Logger.info(
      "Books.Composer: edition #{edition.id} landed despite #{describe(outcome)}; keeping it"
    )
  end

  defp describe({:ok, _}), do: "the turn ended without writing the book's matter"
  defp describe({:timeout, _}), do: "the poet went silent before finishing"
  defp describe({:error, :stale}), do: "the composition never finished"
  defp describe({:error, reason}), do: String.slice("the turn failed: #{inspect(reason)}", 0, 255)
end
