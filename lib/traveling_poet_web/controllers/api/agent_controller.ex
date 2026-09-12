defmodule TravelingPoetWeb.Api.AgentController do
  use TravelingPoetWeb, :controller

  alias TravelingPoet.{Chat, Journal, Markers, Poets, Preferences}
  alias TravelingPoet.Preferences.Cadence
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
            stay_duration_days: Poet.stay_duration_days(poet),
            # "wander" = roam freely; "scout" = pre-visit the itinerary in order
            mode: Poet.mode(poet),
            # brief | balanced | expansive — how long journal prose should run;
            # user-editable in settings, so honor the CURRENT value each run
            verbosity: Map.get(poet.settings || %{}, "verbosity", "balanced")
          },
          location: %{
            lat: poet.current_lat,
            lng: poet.current_lng,
            place_name: poet.current_place_name,
            country_code: poet.current_country_code,
            arrived_at: poet.arrived_at,
            days_here: Poet.days_at_location(poet)
          },
          itinerary: itinerary_for(poet),
          next_stop: next_stop_for(poet),
          # The APP decides whether you move today and where: it already
          # weighs your stay length, any hold your companion asked for in
          # chat, and any detour they added. Obey travel_today.
          travel: Poets.travel_plan(poet),
          latest_entry_date: latest && latest.entry_date,
          today: Date.utc_today(),
          # Which day of the journey today is. The app counts; you never do.
          # Use it in the chat postcard ("Day 17"), not in the entry title.
          journey_day:
            Journal.journey_day(Date.utc_today(), Journal.first_published_date(poet.id)),
          # How many small ink drawings go inside today's text. The app
          # decides (from the companion's verbosity): left to the model, "one
          # if the text runs long" produced none on four poets out of seven.
          drawings: %{spots: spot_target(poet)},
          recent_private_feedback: feedback,
          # What the companion has actually asked for, strongest first. This
          # outranks the poet's own instincts and the interests baked into its
          # workspace at provision time — those are a starting guess, this is
          # what they have since said.
          learned_profile: Preferences.profile_payload(poet.id),
          # Already tried and rejected. Never propose these again.
          dismissed: Preferences.dismissed_payload(poet.id),
          engagement: engagement_for(poet),
          # The APP decides when to ask, not the poet: an agent told to ask
          # "sometimes" asks every time.
          ask_prompt: ask_prompt?(poet)
        })
    end
  end

  # Spot drawings per entry by verbosity. Each is one image (~3 cents); the
  # daily image cap leaves room for the main drawing, these, and a place.
  @spot_targets %{"brief" => 1, "balanced" => 2, "expansive" => 3}

  defp spot_target(poet) do
    Map.get(@spot_targets, Map.get(poet.settings || %{}, "verbosity", "balanced"), 2)
  end

  # Whether the reader is still opening what the poet writes.
  defp engagement_for(poet) do
    recent = Journal.list_entries(poet.id, status: "published", limit: 14)
    opened = Enum.count(recent, & &1.owner_viewed_at)

    %{
      entries_recent: length(recent),
      opened_recent: opened,
      last_opened_at:
        recent
        |> Enum.map(& &1.owner_viewed_at)
        |> Enum.reject(&is_nil/1)
        |> Enum.max(fn -> nil end),
      unopened_streak: recent |> Enum.take_while(&is_nil(&1.owner_viewed_at)) |> length()
    }
  end

  defp ask_prompt?(poet) do
    case Journal.latest_published_entry(poet.id) do
      nil -> false
      latest -> match?({true, _}, Cadence.ask?(poet, latest))
    end
  end

  defp itinerary_for(poet) do
    if Poet.mode(poet) == "scout" do
      Poets.list_stops(poet.id)
      |> Enum.map(fn s ->
        %{
          id: s.id,
          position: s.position,
          place_name: s.place_name,
          lat: s.lat,
          lng: s.lng,
          country_code: s.country_code,
          visited_at: s.visited_at
        }
      end)
    else
      []
    end
  end

  defp next_stop_for(poet) do
    if Poet.mode(poet) == "scout" do
      case Poets.next_pending_stop(poet.id) do
        nil -> nil
        s -> %{id: s.id, position: s.position, place_name: s.place_name, lat: s.lat, lng: s.lng}
      end
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

        # Widened rather than removed on purpose: every already-provisioned
        # sprite has this tool baked in, so enriching what it returns is how
        # existing poets learn about the feedback loop without being
        # re-provisioned. Deleting the route would fail as a tool error
        # mid-ritual instead.
        json(conn, %{
          reactions: Journal.private_feedback_since(poet.id, since),
          learned_profile: Preferences.profile_payload(poet.id),
          dismissed: Preferences.dismissed_payload(poet.id),
          engagement: engagement_for(poet),
          prompt_answers: Preferences.recent_answers(poet.id, since),
          # Passages the companion marked on recent entries (kind, section,
          # quote, whether already delivered). A kind that keeps recurring
          # across days is a taste, not a note about one paragraph.
          markers: Markers.recent_payload(poet.id, since),
          marker_counts: Markers.counts_since(poet.id, since)
        })
    end
  end
end
