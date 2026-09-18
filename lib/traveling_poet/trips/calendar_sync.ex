defmodule TravelingPoet.Trips.CalendarSync do
  @moduledoc """
  Reads every connected companion's Google Calendar and turns what it finds
  into trip suggestions.

  Runs every `:calendar_sync_interval_minutes` (env
  CALENDAR_SYNC_INTERVAL_MINUTES; 0/absent disables, and it is 0 in test,
  where the suite calls `sync_user/1` directly). Companions are synced one
  after another in this one process: geocoding is rate-limited app-wide and
  one bad account must not fan out. A first sync also runs right after a
  connect (`sync_soon/1`).

  One sync is: list the next `:calendar_lookahead_days` of events, geocode
  the locations the detector asks for (through the cache and the limiter,
  at most `@max_locations` new ones per run), detect, reconcile.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias TravelingPoet.{Accounts, Geocoder, GoogleAuth, GoogleCalendar, Poets, Repo, Trips}
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Trips.Detector

  @startup_delay_ms 120_000
  @max_locations 40

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case interval_ms() do
      0 ->
        Logger.info("CalendarSync: disabled")

      interval ->
        Logger.info("CalendarSync: syncing every #{div(interval, 60_000)}m")
        Process.send_after(self(), :sync, min(@startup_delay_ms, interval))
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:sync, state) do
    sync_all()
    Process.send_after(self(), :sync, interval_ms())
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Syncs every connected companion now, ignoring the schedule."
  def check_now, do: GenServer.call(__MODULE__, :check_now, 300_000)

  @impl true
  def handle_call(:check_now, _from, state) do
    {:reply, sync_all(), state}
  end

  @doc "Every companion with a calendar grant and a home, synced in turn."
  def sync_all do
    User
    |> where([u], not is_nil(u.google_refresh_token) and not is_nil(u.home_lat))
    |> Repo.all()
    |> Enum.filter(&GoogleAuth.connected?(&1, :calendar))
    |> Enum.map(fn user ->
      try do
        {user.id, sync_user(user)}
      rescue
        e ->
          Logger.warning("CalendarSync: user #{user.id} raised #{Exception.message(e)}")
          {user.id, {:error, :raised}}
      end
    end)
  end

  @doc """
  Syncs one companion right away, in the background unless configured off
  (as in test). Used after a connect and by "Check now".
  """
  def sync_soon(%User{} = user) do
    if Application.get_env(:traveling_poet, :calendar_sync_in_background, true),
      do: Task.start(fn -> sync_user(user) end),
      else: sync_user(user)

    :ok
  end

  @doc """
  One companion's sync. Returns `{:ok, %{new, updated, withdrawn}}`, or
  `{:error, reason}` with the reason recorded on the user
  (`calendar_error`: "reconnect", "forbidden" or "failed") for the card.
  """
  def sync_user(%User{} = user) do
    today = Date.utc_today()
    user = Accounts.get_user!(user.id)

    with {:ok, poet} <- fetch(Poets.get_poet_by_user(user.id), :no_poet),
         true <- GoogleAuth.connected?(user, :calendar) || {:error, :not_connected},
         {:ok, home} <- fetch(home(user), :no_home),
         {:ok, events, user} <-
           GoogleCalendar.list_events(user, today, Date.add(today, lookahead_days())) do
      resolved = resolve(Detector.locations(events, today, options()))
      detected = Detector.detect(events, resolved, home, today, options())
      result = Trips.reconcile(poet, detected, user.home_place_name)

      {:ok, _} =
        Accounts.update_user(user, %{
          calendar_synced_at: DateTime.utc_now() |> DateTime.truncate(:second),
          calendar_error: nil
        })

      Logger.info(
        "CalendarSync: user #{user.id}: #{length(events)} events, " <>
          "#{length(detected)} trips, #{length(result.new)} new"
      )

      {:ok, result}
    else
      {:error, reason} = error ->
        record_error(user, reason)
        error
    end
  end

  defp fetch(nil, reason), do: {:error, reason}
  defp fetch(value, _reason), do: {:ok, value}

  defp home(%User{home_lat: lat, home_lng: lng}) when is_number(lat) and is_number(lng),
    do: %{lat: lat, lng: lng}

  defp home(_user), do: nil

  # Geocodes through the cache and the limiter; only so many new lookups per
  # run, the rest wait for the next one. A lookup that fails outright is
  # left unresolved (and uncached), so it is tried again next time.
  defp resolve(locations) do
    locations
    |> Enum.take(@max_locations)
    |> Map.new(fn location ->
      case Geocoder.locate(location) do
        {:ok, point} -> {location, point}
        _ -> {location, :not_found}
      end
    end)
  end

  defp record_error(user, reason) do
    code =
      case reason do
        :reconnect -> "reconnect"
        :forbidden -> "forbidden"
        :no_poet -> nil
        :no_home -> nil
        :not_connected -> nil
        _ -> "failed"
      end

    if code, do: Logger.warning("CalendarSync: user #{user.id}: #{inspect(reason)}")

    if code || user.calendar_error,
      do: Accounts.update_user(Accounts.get_user!(user.id), %{calendar_error: code})

    :ok
  end

  defp options do
    %{
      away_km: Application.get_env(:traveling_poet, :trip_away_km, 150),
      same_city_km: Application.get_env(:traveling_poet, :trip_same_city_km, 50),
      max_trip_days: Application.get_env(:traveling_poet, :trip_max_days, 45)
    }
  end

  defp lookahead_days, do: Application.get_env(:traveling_poet, :calendar_lookahead_days, 120)

  defp interval_ms do
    Application.get_env(:traveling_poet, :calendar_sync_interval_minutes, 0) * 60_000
  end
end
