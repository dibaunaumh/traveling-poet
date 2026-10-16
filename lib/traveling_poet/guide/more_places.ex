defmodule TravelingPoet.Guide.MorePlaces do
  @moduledoc """
  "More places" on the trip guide (card-121): a reader who got two
  recommendations at a stop presses a button and the poet goes back out
  for a few more, on the page those places came from.

  The app frames the request, the poet does the finding: one headless
  turn through `AgentSession` on the "system" channel (the press is not a
  message the reader typed, so the chat shows only the poet's reply), with
  an app note that names the stop, the page and what to do. The poet logs
  the places with its ordinary `journal_put_places`, which replaces the
  day's list, so the note tells it to send the old ones along with the
  new; a repeat from an earlier day of the stay is dropped by the endpoint
  as always. The page itself is not rewritten.

  Gated like a chat turn: credits, the daily chat cap, and the sprite's
  busy window (no lock on a sprite; two turns interleave). The turn runs in
  its own task, off the LiveView, and reports to the pid that asked.
  """

  require Logger

  alias TravelingPoet.{Credits, Guide, Journal, Markers, Usage}

  @reply_timeout_ms 10 * 60 * 1000
  @usage_kind "chat_turn"

  @doc """
  Asks the poet for more places at `stay`, reporting `{:more_places, entry_id,
  result}` to `reply_to` when the turn ends (`result` as `AgentSession.run/3`
  returns it). Returns `{:ok, entry}` or `{:error, reason}` with reason one
  of `:no_page` (nothing published at that stop yet), `:credits`, `:cap`,
  `:busy`.
  """
  def request(user, poet, stay, reply_to \\ self()) do
    with {:ok, entry} <- page_for(poet, stay),
         :ok <- gate(user, poet) do
      Usage.record(user.id, @usage_kind, %{metadata: %{"more_places" => entry.id}})
      note = note(poet, entry, stay)
      session = Application.get_env(:traveling_poet, :agent_session, TravelingPoet.AgentSession)

      Task.start(fn ->
        Logger.info("MorePlaces: asking poet #{poet.id} for more at #{stay.place_name}")

        result =
          session.run(user, note, channel: "system", reply_timeout_ms: @reply_timeout_ms)

        case result do
          {:ok, _} -> :ok
          other -> Logger.warning("MorePlaces: poet #{poet.id}: #{inspect(other, limit: 200)}")
        end

        send(reply_to, {:more_places, entry.id, result})
      end)

      {:ok, entry}
    end
  end

  # The page the stop's places came from: the latest published one with
  # places at this stay, else (the poet just arrived) the latest page at all.
  @doc false
  def page_for(poet, stay) do
    latest_with_places =
      poet.id
      |> Guide.list_places(path_point_id: stay.id)
      |> Enum.max_by(& &1.entry_date, Date, fn -> nil end)

    entry =
      case latest_with_places do
        %{journal_entry_id: id} when is_integer(id) -> Journal.get_entry!(id)
        _ -> poet.id |> Journal.list_entries(status: "published", limit: 1) |> List.first()
      end

    if entry && entry.status == "published", do: {:ok, entry}, else: {:error, :no_page}
  end

  defp gate(user, poet) do
    cond do
      Credits.exhausted?(user, poet) -> {:error, :credits}
      not Usage.within_budget?(user, @usage_kind) -> {:error, :cap}
      Markers.Delivery.busy?(user.id, DateTime.utc_now(), chat: false) -> {:error, :busy}
      true -> :ok
    end
  end

  @doc "What the poet is sent: an app note, in the shape of `Asks.frame_reply/2`."
  def note(poet, entry, stay) do
    logged = poet.id |> Guide.list_places(path_point_id: stay.id) |> length()
    date = Date.to_iso8601(entry.entry_date)

    "[From the app: your companion pressed \"More places\" on the trip guide for " <>
      "#{stay.place_name}, on your page of #{date}. They want more than the #{logged} " <>
      "you have logged at this stop. Find three to five more real places here that fit " <>
      "them (their focus and tastes are in get_poet_context), each with a postal address " <>
      "and your own 1-5 rating, and send the WHOLE list for #{date} with journal_put_places: " <>
      "the places already on that page plus the new ones, because the tool replaces the " <>
      "day's list. Do not rewrite the page, do not travel, and do not log a place already " <>
      "in guide.this_stay. Then tell them in a line or two what you found.] " <>
      "More places in #{stay.place_name}, please."
  end
end
