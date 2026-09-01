defmodule TravelingPoet.Geocoder.Limiter do
  @moduledoc """
  Serializes every Nominatim request in the app to OSM's 1 req/s policy.

  A single process IS the rate limit: because all callers queue behind one
  GenServer, the interval cannot be violated no matter how many places a run
  saves or how many people sign up at once.

  This matters beyond the guide. Onboarding and settings geocode on submit
  (`onboarding_live.ex`, `settings_live.ex`), and a burst of signups could
  already earn the app's User-Agent a ban -- which would break signup itself.
  Both now queue here too.
  """

  use GenServer

  require Logger

  alias TravelingPoet.Geocoder

  @call_timeout_ms 20_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  A rate-limited `Geocoder.search/1`.

  Never raises and never propagates an exit: a hung or dead limiter degrades
  to `{:error, reason}`, because nothing in this app should fail because a
  free map service is slow.
  """
  def search(query) do
    if Geocoder.enabled?() do
      GenServer.call(__MODULE__, {:search, query}, @call_timeout_ms)
    else
      # Test env, or geocoding switched off. Nominatim needs no API key, so
      # there is no credential to nil out and this is the only thing standing
      # between the suite and live OSM traffic.
      {:ok, []}
    end
  catch
    :exit, reason ->
      Logger.warning("geocode limiter unavailable: #{inspect(reason)}")
      {:error, :limiter_unavailable}
  end

  @impl true
  def init(_opts), do: {:ok, %{last_at: nil}}

  @impl true
  def handle_call({:search, query}, _from, state) do
    wait_for_slot(state.last_at)
    result = Geocoder.search(query)
    {:reply, result, %{state | last_at: System.monotonic_time(:millisecond)}}
  end

  defp wait_for_slot(nil), do: :ok

  defp wait_for_slot(last_at) do
    interval = Application.get_env(:traveling_poet, :geocode_min_interval_ms, 1100)
    elapsed = System.monotonic_time(:millisecond) - last_at
    if elapsed < interval, do: Process.sleep(interval - elapsed)
    :ok
  end
end
