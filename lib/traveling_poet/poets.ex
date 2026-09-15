defmodule TravelingPoet.Poets do
  @moduledoc """
  The Poets context: poet profiles + journey path.
  """

  import Ecto.Query
  alias TravelingPoet.{Repo, Topics}
  alias TravelingPoet.Poets.{ItineraryStop, Poet, PathPoint}

  def get_poet!(id), do: Repo.get!(Poet, id)
  def get_poet(id), do: Repo.get(Poet, id)
  def get_poet_by_user(user_id), do: Repo.get_by(Poet, user_id: user_id)
  def get_public_poet_by_slug(slug), do: Repo.get_by(Poet, slug: slug, is_public: true)

  def list_public_poets do
    Poet
    |> where(is_public: true, status: "active")
    |> where([p], not is_nil(p.current_lat))
    |> Repo.all()
  end

  @doc """
  Every poet currently on the road, public or not — for the landing map, where
  private poets show as anonymous pins. Callers MUST NOT expose anything but
  coordinates for a poet whose `is_public` is false.
  """
  def list_poets_on_the_road do
    Poet
    |> where(status: "active")
    |> where([p], not is_nil(p.current_lat))
    |> Repo.all()
  end

  def create_poet(attrs) do
    case %Poet{} |> Poet.changeset(attrs) |> Repo.insert() do
      {:error, %{errors: errors} = changeset} ->
        # slug collision → retry with numeric suffixes
        if Keyword.has_key?(errors, :slug) do
          retry_with_suffixed_slug(attrs, changeset)
        else
          {:error, changeset}
        end

      ok ->
        ok
    end
  end

  defp retry_with_suffixed_slug(attrs, original_changeset) do
    base = Poet.slugify(attrs[:name] || attrs["name"] || "poet")

    Enum.reduce_while(2..99, {:error, original_changeset}, fn n, acc ->
      attrs = Map.put(attrs, slug_key(attrs), "#{base}-#{n}")

      case %Poet{} |> Poet.changeset(attrs) |> Repo.insert() do
        {:ok, poet} ->
          {:halt, {:ok, poet}}

        {:error, %{errors: errors}} = err ->
          if Keyword.has_key?(errors, :slug), do: {:cont, acc}, else: {:halt, err}
      end
    end)
  end

  defp slug_key(attrs) when is_map(attrs) do
    if Enum.any?(Map.keys(attrs), &is_binary/1), do: "slug", else: :slug
  end

  def update_poet(%Poet{} = poet, attrs) do
    poet
    |> Poet.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Moves the poet to a new location: closes the current path point (sets
  `departed_at`), appends the next one, and updates the poet's denormalized
  `current_*` fields. Runs in a transaction.
  """
  def move_to(%Poet{} = poet, %{lat: lat, lng: lng} = attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      current = current_path_point(poet.id)

      if current do
        current
        |> PathPoint.changeset(%{departed_at: now})
        |> Repo.update!()
      end

      position = if current, do: current.position + 1, else: 0

      %PathPoint{}
      |> PathPoint.changeset(%{
        poet_id: poet.id,
        lat: lat,
        lng: lng,
        place_name: attrs[:place_name],
        country_code: attrs[:country_code],
        arrived_at: now,
        position: position
      })
      |> Repo.insert!()

      poet
      |> Poet.changeset(%{
        current_lat: lat,
        current_lng: lng,
        current_place_name: attrs[:place_name],
        current_country_code: attrs[:country_code],
        arrived_at: now
      })
      |> Repo.update!()
    end)
  end

  ## Itinerary (Trip Scout mode)

  def list_stops(poet_id) do
    ItineraryStop
    |> where(poet_id: ^poet_id)
    |> order_by(asc: :position)
    |> Repo.all()
  end

  def add_stop(poet_id, attrs) do
    next_position =
      ItineraryStop
      |> where(poet_id: ^poet_id)
      |> select([s], max(s.position))
      |> Repo.one()
      |> case do
        nil -> 0
        max -> max + 1
      end

    %ItineraryStop{}
    |> ItineraryStop.changeset(
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("poet_id", poet_id)
      |> Map.put("position", next_position)
    )
    |> Repo.insert()
  end

  def remove_stop(poet_id, stop_id) do
    case Repo.get_by(ItineraryStop, id: stop_id, poet_id: poet_id) do
      nil -> {:error, :not_found}
      stop -> Repo.delete(stop)
    end
  end

  ## Route requests from chat

  @max_hold_days 30

  @doc """
  Keeps the poet where it is for `days` more days beyond `today`. "Stay one
  more day" said on the 9th means the run on the 10th stays; the 11th moves.
  """
  def hold(%Poet{} = poet, days, today \\ Date.utc_today()) when is_integer(days) do
    days = days |> max(1) |> min(@max_hold_days)
    update_poet(poet, %{hold_until: Date.add(today, days)})
  end

  def release_hold(%Poet{} = poet), do: update_poet(poet, %{hold_until: nil})

  def held?(%Poet{hold_until: nil}, _today), do: false
  def held?(%Poet{hold_until: until}, today), do: Date.compare(today, until) != :gt

  @doc """
  Inserts a stop AHEAD of the next pending one: a detour the companion asked
  for in chat. Later pending stops shift back one place; visited stops keep
  their positions.
  """
  def insert_stop_next(poet_id, attrs) do
    Repo.transaction(fn ->
      position =
        case next_pending_stop(poet_id) do
          nil -> next_position(poet_id)
          stop -> stop.position
        end

      # One at a time, last first, so a unique (poet, position) index could
      # never see two rows on the same number mid-shift.
      ItineraryStop
      |> where([s], s.poet_id == ^poet_id and s.position >= ^position)
      |> order_by(desc: :position)
      |> Repo.all()
      |> Enum.each(fn s ->
        s |> Ecto.Changeset.change(position: s.position + 1) |> Repo.update!()
      end)

      %ItineraryStop{}
      |> ItineraryStop.changeset(
        attrs
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.put("poet_id", poet_id)
        |> Map.put("position", position)
        |> Map.put_new("source", "chat")
      )
      |> Repo.insert()
      |> case do
        {:ok, stop} -> stop
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp next_position(poet_id) do
    ItineraryStop
    |> where(poet_id: ^poet_id)
    |> select([s], max(s.position))
    |> Repo.one()
    |> case do
      nil -> 0
      max -> max + 1
    end
  end

  @doc """
  The app's decision on whether the poet moves today, and where to.

  The daily run used to decide this itself from the day count, which meant a
  request made in chat ("stay one more day", "see Catalina first") lived only
  in the model's memory of a previous conversation and lost to the itinerary
  data the next morning. Now the request is data (a hold, a detour stop) and
  the decision is made here, once, for the poet to obey.

  Returns `%{travel_today, reason, destination, days_here, stay_duration_days,
  hold_until}`. `destination` is the next pending stop (scout mode), or a
  stop the companion asked for in chat (either mode); nil means the wanderer
  picks somewhere itself.
  """
  def travel_plan(%Poet{} = poet, today \\ Date.utc_today()) do
    days_here = days_here(poet, today)
    stay = Poet.stay_duration_days(poet)
    scout? = Poet.mode(poet) == "scout"
    next = if scout?, do: next_pending_stop(poet.id), else: next_requested_stop(poet.id)

    base = %{
      days_here: days_here,
      stay_duration_days: stay,
      hold_until: poet.hold_until,
      destination: next && stop_payload(next),
      # Where the poet has already stayed, so a free choice is a new place.
      visited: poet.id |> visited_stays() |> Enum.map(& &1.place_name) |> Enum.uniq()
    }

    route =
      cond do
        held?(poet, today) ->
          decide(base, false, "your companion asked you to stay here through #{poet.hold_until}")

        next && next.source == "chat" ->
          decide(base, true, "your companion asked for this stop in chat; go there today")

        days_here < stay ->
          decide(base, false, "day #{days_here + 1} of #{stay} here; not yet time to move")

        scout? and is_nil(next) ->
          decide(
            base,
            false,
            "itinerary complete: stay at this final stop and go deeper; ask whether to add stops"
          )

        scout? ->
          decide(base, true, "your stay here is done; advance to the next planned stop")

        true ->
          decide(
            base,
            true,
            "your stay here is done; pick somewhere real and nearby that is NOT in `visited`"
          )
      end

    with_excursion(route, poet, today)
  end

  # An excursion is a stay day spent off the road, into one of the
  # companion's topics. It never displaces a move (a chat-requested stop and
  # a chat-requested excursion both pending: the move goes first), never
  # follows another excursion, and a row already on today's date wins so a
  # retried run makes the same decision. Otherwise a queued chat request
  # goes before the cadence.
  defp with_excursion(route, poet, today) do
    today_row = Topics.excursion_for_today(poet.id, today)

    cond do
      today_row ->
        excursion(route, today_row)

      route.travel_today ->
        Map.merge(route, %{day: "move", excursion: nil})

      Topics.excursion_yesterday?(poet.id, today) ->
        Map.merge(route, %{day: "stay", excursion: nil})

      queued = Topics.queued_chat_excursion(poet.id) ->
        excursion(route, queued)

      topic = Topics.due_topic(poet.id, today) ->
        excursion(route, %Topics.Excursion{
          id: nil,
          topic_id: topic.id,
          topic: topic,
          source: "app"
        })

      true ->
        Map.merge(route, %{day: "stay", excursion: nil})
    end
  end

  defp excursion(route, %Topics.Excursion{} = x) do
    label = x.topic && x.topic.label

    asked =
      if x.source == "chat", do: " (your companion asked for #{x.requested_venue})", else: ""

    Map.merge(route, %{
      travel_today: false,
      day: "excursion",
      excursion: Topics.excursion_payload(x),
      reason:
        "an excursion into #{label}#{asked}: a day at your desk, not on the road; " <>
          "you do not move today and it does not count against your stay"
    })
  end

  @doc """
  Days the poet has spent AT the place: calendar days since arrival minus
  the excursion days taken there. An excursion is a day off the road, so a
  three-day stay with one excursion lasts four calendar days and the place
  still gets its three entries. Both the travel plan and the agent context
  read this, so they never disagree.
  """
  def days_here(%Poet{} = poet, _today \\ Date.utc_today()) do
    arrived_on = poet.arrived_at && DateTime.to_date(poet.arrived_at)
    excursions = Topics.excursion_days_since(poet.id, arrived_on)
    max(Poet.days_at_location(poet) - excursions, 0)
  end

  defp decide(base, travel?, reason),
    do: Map.merge(base, %{travel_today: travel?, reason: reason})

  defp stop_payload(stop) do
    %{
      id: stop.id,
      position: stop.position,
      place_name: stop.place_name,
      lat: stop.lat,
      lng: stop.lng,
      country_code: stop.country_code,
      source: stop.source
    }
  end

  # A wandering poet ignores the Settings itinerary (it is for a future scout
  # trip) but does go where the companion sent it in chat.
  defp next_requested_stop(poet_id) do
    ItineraryStop
    |> where(poet_id: ^poet_id, source: "chat")
    |> where([s], is_nil(s.visited_at))
    |> order_by(asc: :position)
    |> limit(1)
    |> Repo.one()
  end

  def next_pending_stop(poet_id) do
    ItineraryStop
    |> where(poet_id: ^poet_id)
    |> where([s], is_nil(s.visited_at))
    |> order_by(asc: :position)
    |> limit(1)
    |> Repo.one()
  end

  def mark_stop_visited(poet_id, stop_id) do
    case Repo.get_by(ItineraryStop, id: stop_id, poet_id: poet_id) do
      nil ->
        {:error, :not_found}

      stop ->
        stop
        |> ItineraryStop.changeset(%{
          visited_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()
    end
  end

  def current_path_point(poet_id) do
    PathPoint
    |> where(poet_id: ^poet_id)
    |> where([p], is_nil(p.departed_at))
    |> order_by(desc: :position)
    |> limit(1)
    |> Repo.one()
  end

  def list_path_points(poet_id) do
    PathPoint
    |> where(poet_id: ^poet_id)
    |> order_by(asc: :position)
    |> Repo.all()
  end

  @doc """
  The stays before the current one, oldest first: where the poet has already
  been. A wandering poet was told to "pick somewhere nearby" with no memory
  of its own path, and the fleet bounced between the same two or three towns
  (Reno, Truckee, Reno; Asheville three times), writing each return as a
  first arrival. The app holds the path; the poet is told.
  """
  def visited_stays(poet_id) do
    case list_path_points(poet_id) do
      [] ->
        []

      points ->
        points
        |> Enum.drop(-1)
        |> Enum.map(fn p ->
          %{
            place_name: p.place_name,
            arrived_on: p.arrived_at && DateTime.to_date(p.arrived_at),
            departed_on: p.departed_at && DateTime.to_date(p.departed_at)
          }
        end)
    end
  end

  @doc "Whether the poet's current place is one it has stayed in before."
  def returning?(%Poet{current_place_name: name} = poet) when is_binary(name) do
    poet.id
    |> visited_stays()
    |> Enum.any?(&same_place?(&1.place_name, name))
  end

  def returning?(_poet), do: false

  defp same_place?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(String.trim(a)) == String.downcase(String.trim(b))

  defp same_place?(_, _), do: false
end
