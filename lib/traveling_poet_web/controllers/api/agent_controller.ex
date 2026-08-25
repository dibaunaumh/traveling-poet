defmodule TravelingPoetWeb.Api.AgentController do
  use TravelingPoetWeb, :controller

  alias TravelingPoet.{Chat, Journal, Poets}
  alias TravelingPoet.Poets.Poet

  @doc """
  Compact digest of recent chat history — the agent's `get_conversation_memory`
  tool calls this at the start of each conversation.
  """
  def memory(conn, _params) do
    user = conn.assigns.agent_user
    messages = Chat.list_recent_messages(user.id, 30)

    summary =
      case messages do
        [] ->
          nil

        msgs ->
          msgs
          |> Enum.map_join("\n", fn m ->
            who = if m.role == "user", do: "Companion", else: "You"
            "#{who}: #{String.slice(m.content, 0, 500)}"
          end)
      end

    json(conn, %{summary: summary})
  end

  @doc "Poet profile + current location + short feedback digest."
  def context(conn, _params) do
    user = conn.assigns.agent_user

    case Poets.get_poet_by_user(user.id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "no poet configured"})

      poet ->
        two_weeks_ago = DateTime.add(DateTime.utc_now(), -14, :day)
        feedback = Journal.private_feedback_since(poet.id, two_weeks_ago)
        latest = Journal.latest_published_entry(poet.id)

        json(conn, %{
          poet: %{
            name: poet.name,
            personality: poet.personality,
            interests: poet.interests,
            currently_reading: Map.get(poet.currently_reading || %{}, "items", []),
            is_public: poet.is_public,
            stay_duration_days: Poet.stay_duration_days(poet)
          },
          location: %{
            lat: poet.current_lat,
            lng: poet.current_lng,
            place_name: poet.current_place_name,
            country_code: poet.current_country_code,
            arrived_at: poet.arrived_at,
            days_here: Poet.days_at_location(poet)
          },
          latest_entry_date: latest && latest.entry_date,
          today: Date.utc_today(),
          recent_private_feedback: feedback
        })
    end
  end

  @doc "The owner's private reactions over the last 14 days."
  def feedback(conn, _params) do
    user = conn.assigns.agent_user

    case Poets.get_poet_by_user(user.id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "no poet configured"})

      poet ->
        since = DateTime.add(DateTime.utc_now(), -14, :day)
        json(conn, %{reactions: Journal.private_feedback_since(poet.id, since)})
    end
  end
end
