defmodule TravelingPoet.Trips.Detector do
  @moduledoc """
  Finds trips in a list of calendar events. Pure: plain maps in, plain maps
  out, no Repo and no HTTP, so every rule is testable on its own.

  A trip is days spent somewhere far from home. The signals, in the order
  they are trusted:

    * events Gmail made from a booking (`event_type` "fromGmail": flights,
      trains, hotels) with a location;
    * ordinary events with a location that cover at least two calendar days;
    * out-of-office blocks, which never make a trip on their own but widen
      one they overlap.

  Only an event's location is read, never its title. Locations are resolved
  by the caller (`locations/2` says which ones are worth geocoding) and
  handed in as `resolved`; anything unresolved, or within `away_km` of home,
  is not travel.

  Candidates are clustered into trips when they overlap or abut in time and
  are either two booking legs of one journey or in the same city. A trip's
  destinations are its cities in order of arrival.
  """

  alias TravelingPoet.Geo

  @defaults %{
    # farther than this from home counts as away
    away_km: 150,
    # events this close together are the same city
    same_city_km: 50,
    # a day between two events still joins them
    gap_days: 1,
    # an ordinary event must cover this many calendar days
    min_stay_days: 2,
    # longer than this is a move, not a trip
    max_trip_days: 45,
    # a trip starting sooner than this cannot be scouted
    min_lead_days: 2
  }

  @skip_types ~w(birthday workingLocation focusTime)

  def defaults, do: @defaults

  @doc "The distinct locations worth geocoding: those of candidate events still ahead."
  def locations(events, today, opts \\ %{}) do
    events
    |> candidates(today, options(opts))
    |> Enum.reject(&(&1.kind == :ooo))
    |> Enum.map(& &1.location)
    |> Enum.uniq()
  end

  @doc """
  The trips in `events`. `resolved` maps a location string to
  `%{lat, lng, country_code, city, country}` (or `:not_found`); `home` is
  `%{lat, lng}`.

  Returns `[%{name, start_date, end_date, destinations, event_ids, signals}]`
  sorted by start date.
  """
  def detect(events, resolved, %{lat: _, lng: _} = home, today, opts \\ %{}) do
    opts = options(opts)
    candidates = candidates(events, today, opts)

    {ooo, dated} = Enum.split_with(candidates, &(&1.kind == :ooo))

    dated
    |> Enum.flat_map(&locate(&1, resolved, home, opts))
    |> Enum.sort_by(&{Date.to_iso8601(&1.start_on), Date.to_iso8601(&1.end_on)})
    |> cluster(opts)
    |> Enum.map(&envelope(&1, ooo, opts))
    |> Enum.map(&trip(&1, opts))
    |> Enum.reject(&too_long?(&1, opts))
    |> Enum.reject(&too_soon?(&1, today, opts))
    |> Enum.sort_by(& &1.start_date, Date)
  end

  # -- candidates --

  defp candidates(events, today, opts) do
    events
    |> Enum.reject(&(&1[:status] == "cancelled" or &1[:event_type] in @skip_types))
    |> Enum.reject(&(is_nil(&1[:start_on]) or is_nil(&1[:end_on])))
    |> Enum.reject(&(Date.compare(&1.end_on, today) == :lt))
    |> Enum.flat_map(&candidate(&1, opts))
  end

  defp candidate(%{event_type: "outOfOffice"} = event, _opts), do: [Map.put(event, :kind, :ooo)]

  defp candidate(%{event_type: "fromGmail"} = event, _opts) do
    if located?(event), do: [Map.put(event, :kind, :gmail)], else: []
  end

  defp candidate(event, opts) do
    if located?(event) and days(event.start_on, event.end_on) >= opts.min_stay_days,
      do: [Map.put(event, :kind, :stay)],
      else: []
  end

  defp located?(event), do: is_binary(event[:location]) and String.trim(event.location) != ""

  defp days(from, to), do: Date.diff(to, from) + 1

  # -- where --

  defp locate(candidate, resolved, home, opts) do
    case Map.get(resolved, candidate.location) do
      %{lat: lat, lng: lng} = point when is_number(lat) and is_number(lng) ->
        if Geo.distance_km(lat, lng, home.lat, home.lng) > opts.away_km,
          do: [Map.put(candidate, :point, point)],
          else: []

      _ ->
        []
    end
  end

  # -- clustering --

  defp cluster(located, opts) do
    located
    |> Enum.reduce([], fn c, clusters ->
      case clusters do
        [open | rest] ->
          if joins?(c, open, opts),
            do: [join(open, c) | rest],
            else: [new_cluster(c), open | rest]

        [] ->
          [new_cluster(c)]
      end
    end)
    |> Enum.reverse()
  end

  defp new_cluster(c), do: %{start_on: c.start_on, end_on: c.end_on, members: [c], ooo: []}

  defp join(cluster, c) do
    %{
      cluster
      | end_on: Enum.max([cluster.end_on, c.end_on], Date),
        members: cluster.members ++ [c]
    }
  end

  defp joins?(c, cluster, opts) do
    Date.diff(c.start_on, cluster.end_on) <= opts.gap_days and
      (legs_of_one_journey?(c, cluster) or same_city_as_any?(c, cluster.members, opts))
  end

  defp legs_of_one_journey?(%{kind: :gmail}, cluster),
    do: Enum.any?(cluster.members, &(&1.kind == :gmail))

  defp legs_of_one_journey?(_c, _cluster), do: false

  defp same_city_as_any?(c, members, opts),
    do: Enum.any?(members, &same_city?(c.point, &1.point, opts))

  defp same_city?(a, b, opts),
    do: Geo.distance_km(a.lat, a.lng, b.lat, b.lng) <= opts.same_city_km

  # An out-of-office block that overlaps or abuts a trip widens it. One that
  # overlaps nothing says nothing about where they went.
  defp envelope(cluster, ooo, opts) do
    Enum.reduce(ooo, cluster, fn block, acc ->
      if Date.diff(block.start_on, acc.end_on) <= opts.gap_days and
           Date.diff(acc.start_on, block.end_on) <= opts.gap_days do
        %{
          acc
          | start_on: Enum.min([acc.start_on, block.start_on], Date),
            end_on: Enum.max([acc.end_on, block.end_on], Date),
            ooo: acc.ooo ++ [block]
        }
      else
        acc
      end
    end)
  end

  # -- the trip --

  defp trip(cluster, opts) do
    destinations = destinations(cluster.members, opts)
    events = cluster.members ++ cluster.ooo

    %{
      name: name(destinations),
      start_date: cluster.start_on,
      end_date: cluster.end_on,
      destinations: destinations,
      event_ids: Enum.map(events, & &1.id),
      signals: Enum.map(events, &signal/1)
    }
  end

  # One destination per city, in order of arrival: members are grouped by
  # nearness to the first member seen there.
  defp destinations(members, opts) do
    members
    |> Enum.reduce([], fn m, groups ->
      case Enum.find_index(groups, &same_city?(m.point, &1.point, opts)) do
        nil -> groups ++ [%{point: m.point, location: m.location, members: [m]}]
        i -> List.update_at(groups, i, &%{&1 | members: &1.members ++ [m]})
      end
    end)
    |> Enum.map(fn group ->
      point = group.point

      %{
        place_name: place_name(point, group.location),
        lat: point.lat,
        lng: point.lng,
        country_code: point[:country_code],
        arrive_on: group.members |> Enum.map(& &1.start_on) |> Enum.min(Date),
        depart_on: group.members |> Enum.map(& &1.end_on) |> Enum.max(Date)
      }
    end)
    |> Enum.sort_by(& &1.arrive_on, Date)
  end

  defp place_name(point, location) do
    city = present(point[:city]) || location |> String.split(",") |> List.first() |> String.trim()

    case present(point[:country]) do
      nil -> city
      country -> "#{city}, #{country}"
    end
  end

  defp name(destinations) do
    case Enum.map(destinations, &city_of/1) do
      [one] -> one
      [a, b] -> "#{a} and #{b}"
      [a, b | rest] -> "#{a}, #{b} and #{length(rest)} more"
      [] -> "A trip"
    end
  end

  defp city_of(%{place_name: name}),
    do: name |> String.split(",") |> List.first() |> String.trim()

  defp signal(event) do
    %{
      id: event.id,
      ical_uid: event[:ical_uid],
      kind: Atom.to_string(event.kind),
      start: Date.to_iso8601(event.start_on),
      end: Date.to_iso8601(event.end_on),
      location: event[:location]
    }
  end

  defp too_long?(trip, opts), do: days(trip.start_date, trip.end_date) > opts.max_trip_days

  defp too_soon?(trip, today, opts), do: Date.diff(trip.start_date, today) < opts.min_lead_days

  defp options(opts), do: Map.merge(@defaults, Map.new(opts))

  defp present(nil), do: nil
  defp present(text) when is_binary(text), do: if(String.trim(text) == "", do: nil, else: text)
  defp present(_), do: nil
end
