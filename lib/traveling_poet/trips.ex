defmodule TravelingPoet.Trips do
  @moduledoc """
  The companion's upcoming trips and what the poet does about them.

  A trip found on the calendar is a suggestion (`status` "suggested") until
  the companion answers: "Scout this trip" plans it (the destinations become
  itinerary stops with `source` "trip"), "Not this trip" dismisses it. A
  dismissed trip is kept so the next sync does not offer it again.

  `reconcile/4` is the one place a sync touches trips: it matches what the
  detector found against what is stored, so a re-sync neither duplicates a
  suggestion nor loses a decision, and a suggestion whose events left the
  calendar is withdrawn.
  """

  import Ecto.Query

  alias TravelingPoet.{Geo, Poets, Repo}
  alias TravelingPoet.Poets.{ItineraryStop, Poet}
  alias TravelingPoet.Trips.Trip

  @doc "Whether the poet scouts today: its mission is scout, or a planned trip's day has come."
  def scouting?(%Poet{} = poet, today \\ Date.utc_today()) do
    Poet.mode(poet) == "scout" or active_trip(poet, today) != nil
  end

  @same_city_km 50

  # -- reading --

  def list(poet_id) do
    Trip
    |> where(poet_id: ^poet_id)
    |> order_by(asc: :start_date, asc: :id)
    |> Repo.all()
  end

  def list_by_status(poet_id, statuses) when is_list(statuses) do
    Trip
    |> where([t], t.poet_id == ^poet_id and t.status in ^statuses)
    |> order_by(asc: :start_date, asc: :id)
    |> Repo.all()
  end

  def suggested(poet_id), do: list_by_status(poet_id, ["suggested"])

  def get(poet_id, id), do: Repo.get_by(Trip, id: id, poet_id: poet_id)

  def stops(trip_id) do
    ItineraryStop |> where(trip_id: ^trip_id) |> order_by(asc: :position) |> Repo.all()
  end

  @doc """
  Whether the calendar connection is offered to this companion:
  `:calendar_enabled` is "all", "admins" (while Google verifies the scope)
  or "off".
  """
  def enabled_for?(user) do
    case Application.get_env(:traveling_poet, :calendar_enabled, "admins") do
      "all" -> true
      "admins" -> user.is_admin == true
      _ -> false
    end
  end

  # -- the sync --

  @doc """
  Brings the stored trips in line with what the detector found. Each found
  trip is matched to a stored one by a shared calendar event id, else by
  the same first city and overlapping dates. Then:

    * unmatched -> a new suggestion (broadcast `{:trip_suggested, ...}`);
    * suggested -> updated; `changed_at` set when dates or cities moved;
    * dismissed, planned, scouting, done -> only the event ids follow, so the
      decision stands and the trip keeps matching.

  Suggestions nothing matched, or already started, are withdrawn (deleted);
  a decided trip is never deleted here. Returns `%{new, updated, withdrawn}`.
  """
  def reconcile(%Poet{} = poet, detected, home_place_name, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    today = DateTime.to_date(now)
    existing = list(poet.id)

    {new, updated, matched_ids} =
      Enum.reduce(detected, {[], 0, MapSet.new()}, fn found, {new, updated, matched} ->
        case match(found, Enum.reject(existing, &MapSet.member?(matched, &1.id))) do
          nil ->
            {:ok, trip} = insert_suggestion(poet, found, home_place_name, now)
            {[trip | new], updated, matched}

          trip ->
            {:ok, _} = follow(trip, found, now)
            {new, updated + 1, MapSet.put(matched, trip.id)}
        end
      end)

    withdrawn =
      existing
      |> Enum.filter(&(&1.status == "suggested"))
      |> Enum.filter(fn t ->
        not MapSet.member?(matched_ids, t.id) or Date.compare(t.start_date, today) == :lt
      end)
      |> Enum.map(&Repo.delete!/1)
      |> length()

    new = Enum.reverse(new)

    for trip <- new do
      Phoenix.PubSub.broadcast(
        TravelingPoet.PubSub,
        "trips",
        {:trip_suggested, poet.user_id, trip.id}
      )
    end

    if new != [] or updated > 0 or withdrawn > 0, do: broadcast_updated(poet)

    %{new: new, updated: updated, withdrawn: withdrawn}
  end

  defp match(found, candidates) do
    Enum.find(candidates, &shares_event?(&1, found)) ||
      Enum.find(candidates, &same_trip?(&1, found))
  end

  defp shares_event?(trip, found), do: Enum.any?(found.event_ids, &(&1 in trip.event_ids))

  defp same_trip?(trip, found) do
    with [first | _] <- Trip.destinations(trip),
         [%{lat: lat, lng: lng} | _] <- found.destinations do
      Geo.distance_km(first["lat"], first["lng"], lat, lng) <= @same_city_km and
        Date.compare(found.start_date, trip.end_date) != :gt and
        Date.compare(trip.start_date, found.end_date) != :gt
    else
      _ -> false
    end
  end

  defp insert_suggestion(poet, found, home_place_name, now) do
    %Trip{}
    |> Trip.changeset(
      Map.merge(found_attrs(found), %{
        poet_id: poet.id,
        status: "suggested",
        source: "calendar",
        home_place_name: home_place_name,
        suggested_at: now
      })
    )
    |> Repo.insert()
  end

  defp follow(%Trip{status: "suggested"} = trip, found, now) do
    attrs = found_attrs(found)

    changed? =
      trip.start_date != found.start_date or trip.end_date != found.end_date or
        Enum.map(Trip.destinations(trip), & &1["place_name"]) !=
          Enum.map(found.destinations, & &1.place_name)

    attrs = if changed?, do: Map.put(attrs, :changed_at, now), else: attrs
    trip |> Trip.changeset(attrs) |> Repo.update()
  end

  # A planned trip follows the calendar's dates (the poet must set out in
  # time); its stops and decision stand.
  defp follow(%Trip{status: status} = trip, found, now) when status in ["planned", "scouting"] do
    moved? = trip.start_date != found.start_date or trip.end_date != found.end_date

    attrs = %{event_ids: Enum.uniq(trip.event_ids ++ found.event_ids)}

    attrs =
      if moved?,
        do:
          Map.merge(attrs, %{
            start_date: found.start_date,
            end_date: found.end_date,
            changed_at: now,
            scout_from:
              scout_from(found.start_date, stay_count(trip), Poets.get_poet(trip.poet_id))
          }),
        else: attrs

    trip |> Trip.changeset(attrs) |> Repo.update()
  end

  defp follow(%Trip{} = trip, found, _now) do
    trip
    |> Trip.changeset(%{event_ids: Enum.uniq(trip.event_ids ++ found.event_ids)})
    |> Repo.update()
  end

  defp found_attrs(found) do
    %{
      name: found.name,
      start_date: found.start_date,
      end_date: found.end_date,
      destinations: %{"items" => Enum.map(found.destinations, &stringify/1)},
      event_ids: found.event_ids,
      signals: %{"events" => Enum.map(found.signals, &stringify/1)}
    }
  end

  defp stringify(map) do
    Map.new(map, fn
      {k, %Date{} = d} -> {to_string(k), Date.to_iso8601(d)}
      {k, v} -> {to_string(k), v}
    end)
  end

  # -- decisions --

  @doc """
  The companion wants the poet to scout this trip: the destinations become
  itinerary stops (source "trip") and the trip is planned, with the day the
  poet sets out (`scout_from`) computed from the stops and the poet's stay
  length. Idempotent.
  """
  def accept(%Poet{} = poet, %Trip{poet_id: poet_id} = trip, today \\ Date.utc_today())
      when poet_id == poet.id do
    if stops(trip.id) == [] do
      for d <- Trip.destinations(trip) do
        {:ok, _} =
          Poets.add_stop(poet.id, %{
            place_name: d["place_name"],
            lat: d["lat"],
            lng: d["lng"],
            country_code: d["country_code"],
            source: "trip",
            trip_id: trip.id
          })
      end
    end

    from = scout_from(trip.start_date, stay_count(trip), poet)
    status = if Date.compare(from, today) == :gt, do: "planned", else: "scouting"

    result =
      trip
      |> Trip.changeset(%{status: status, scout_from: from, decided_at: now()})
      |> Repo.update()

    broadcast_updated(poet)
    result
  end

  # -- timing --

  @doc """
  The day the poet sets out to scout a trip starting on `start_date`: one
  full stay at each of `stays` stops, plus a day, before the companion
  leaves. Never before today's caller decides otherwise.
  """
  def scout_from(%Date{} = start_date, stays, %Poet{} = poet) when is_integer(stays) do
    Date.add(start_date, -(max(stays, 1) * Poet.stay_duration_days(poet) + 1))
  end

  # The stops still to be scouted (or the destinations, before any stop exists).
  defp stay_count(%Trip{} = trip) do
    case stops(trip.id) do
      [] -> length(Trip.destinations(trip))
      stops -> max(Enum.count(stops, &is_nil(&1.visited_at)), 1)
    end
  end

  @doc """
  The trip the poet is scouting today, if any: the earliest planned or
  scouting trip whose `scout_from` has come and that still has a stop to
  reach, or whose last stop is where the poet now stands (the stay there is
  part of the trip). Read-only; `activate/2` records the state change.
  """
  def active_trip(%Poet{} = poet, today \\ Date.utc_today()) do
    poet.id
    |> list_by_status(~w(planned scouting))
    |> Enum.filter(&(&1.scout_from && Date.compare(&1.scout_from, today) != :gt))
    |> Enum.sort_by(&{Date.to_iso8601(&1.scout_from), &1.id})
    |> Enum.find(fn trip ->
      stops = stops(trip.id)
      Enum.any?(stops, &is_nil(&1.visited_at)) or at_last_stop?(poet, stops)
    end)
  end

  @doc "The trip's next stop still to be reached, skipping one the poet already stands at."
  def next_stop(%Poet{} = poet, %Trip{} = trip) do
    trip.id
    |> stops()
    |> Enum.filter(&is_nil(&1.visited_at))
    |> Enum.drop_while(&Poets.at_place?(&1, poet))
    |> List.first()
  end

  @doc "Whether the poet stands at one of the trip's stops already reached."
  def at_trip_stop?(%Poet{} = poet, %Trip{} = trip) do
    trip.id |> stops() |> Enum.any?(&(&1.visited_at && Poets.at_place?(&1, poet)))
  end

  defp at_last_stop?(poet, stops) do
    case List.last(stops) do
      nil -> false
      last -> last.visited_at != nil and Poets.at_place?(last, poet)
    end
  end

  @doc """
  Records the day's state before a run: a planned trip whose day has come
  becomes `scouting`; a scouting trip whose stops are all reached and whose
  last stay is over (or whose start date has passed) is `done`. Returns the
  trip being scouted today, if any.
  """
  def activate(%Poet{} = poet, today \\ Date.utc_today()) do
    for trip <- list_by_status(poet.id, ~w(planned scouting)), finished?(poet, trip, today) do
      {:ok, _} = trip |> Trip.changeset(%{status: "done"}) |> Repo.update()
    end

    case active_trip(poet, today) do
      %Trip{status: "planned"} = trip ->
        {:ok, trip} = trip |> Trip.changeset(%{status: "scouting"}) |> Repo.update()
        broadcast_updated(poet)
        trip

      other ->
        other
    end
  end

  defp finished?(poet, trip, today) do
    stops = stops(trip.id)
    all_reached? = stops != [] and Enum.all?(stops, & &1.visited_at)

    all_reached? and
      (Date.compare(today, trip.start_date) == :gt or
         not at_last_stop?(poet, stops) or
         Poets.days_here(poet, today) >= Poet.stay_duration_days(poet))
  end

  @doc "A trip stop was removed in Settings: the trip is rescheduled, or called off with its last stop."
  def after_stop_removed(%Poet{} = poet, trip_id) when is_integer(trip_id) do
    case get(poet.id, trip_id) do
      %Trip{status: status} = trip when status in ["planned", "scouting"] ->
        if Enum.any?(stops(trip.id), &is_nil(&1.visited_at)) do
          trip
          |> Trip.changeset(%{scout_from: scout_from(trip.start_date, stay_count(trip), poet)})
          |> Repo.update()
        else
          dismiss(trip)
        end

      _ ->
        :ok
    end
  end

  def after_stop_removed(_poet, _trip_id), do: :ok

  @doc "What the agent is told about the trip it is scouting."
  def payload(nil), do: nil

  def payload(%Trip{} = trip) do
    %{
      id: trip.id,
      name: trip.name,
      start_date: trip.start_date,
      end_date: trip.end_date,
      scout_from: trip.scout_from,
      destinations: Enum.map(Trip.destinations(trip), & &1["place_name"])
    }
  end

  @doc "Not this trip. Kept, so the next sync does not suggest it again."
  def dismiss(%Trip{} = trip) do
    trip |> Trip.changeset(%{status: "dismissed", decided_at: now()}) |> Repo.update()
  end

  @doc "Calls off a planned trip: its unvisited stops go, the trip is dismissed."
  def cancel(%Poet{} = poet, %Trip{poet_id: poet_id} = trip) when poet_id == poet.id do
    ItineraryStop
    |> where([s], s.trip_id == ^trip.id and is_nil(s.visited_at))
    |> Repo.delete_all()

    result = dismiss(trip)
    broadcast_updated(poet)
    result
  end

  @doc "Drops every open suggestion, as when the calendar is disconnected."
  def withdraw_suggestions(poet_id) do
    {count, _} =
      Trip |> where([t], t.poet_id == ^poet_id and t.status == "suggested") |> Repo.delete_all()

    count
  end

  # -- words --

  @doc ~S|"3 to 9 October", "28 September to 3 October", "30 December to 2 January 2027".|
  def date_range(%Date{} = from, %Date{} = to) do
    cond do
      from == to ->
        day(from)

      from.year == to.year and from.month == to.month ->
        "#{from.day} to #{day(to)}"

      from.year == to.year ->
        "#{day(from)} to #{day(to)}"

      true ->
        "#{day(from)} to #{day(to)} #{to.year}"
    end
  end

  defp day(date), do: Calendar.strftime(date, "%-d %B")

  defp broadcast_updated(%Poet{user_id: user_id}) do
    Phoenix.PubSub.broadcast(TravelingPoet.PubSub, "user:#{user_id}", {:trips_updated})
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
