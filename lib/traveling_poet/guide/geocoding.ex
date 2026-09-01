defmodule TravelingPoet.Guide.Geocoding do
  @moduledoc """
  Turns place addresses into map pins.

  Split into a synchronous best-effort pass with a time budget, plus a
  background drain for whatever did not fit. The synchronous half exists so
  the agent's own tool response can name the addresses that could not be
  found -- the poet has no callback, so if this were fully asynchronous the
  skill's coaching ("a place the app can't find gets no pin") would have
  nothing to attach to.

  Nothing here is allowed to fail a write. Every outcome -- found, not found,
  network error, limiter down -- leaves the place saved and listed.
  """

  require Logger

  alias TravelingPoet.Geocoder
  alias TravelingPoet.Guide
  alias TravelingPoet.Guide.Place

  @budget_ms 6_000

  @doc """
  Resolves as many of `places` as fit inside the time budget. Returns the
  reloaded places plus the names that got no pin, for the API response.

  Cache hits cost nothing, so a re-put of a day already geocoded finishes
  instantly and inside the budget every time.
  """
  def resolve_within_budget(places, city, budget_ms \\ @budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms

    resolved =
      Enum.map(places, fn place ->
        if System.monotonic_time(:millisecond) < deadline do
          resolve(place, city)
        else
          place
        end
      end)

    not_located =
      resolved
      |> Enum.reject(&Place.mapped?/1)
      |> Enum.map(& &1.name)

    {resolved, not_located}
  end

  @doc """
  Resolves one place. Already-geocoded places are left alone, so this is safe
  to call repeatedly.
  """
  def resolve(%Place{geocode_status: "ok"} = place, _city), do: place

  def resolve(%Place{} = place, city) do
    case Geocoder.locate(Guide.geocode_query(place, city)) do
      {:ok, coords} ->
        case Guide.update_geocode(place, coords) do
          {:ok, updated} -> updated
          {:error, _} -> place
        end

      :not_found ->
        mark_failed(place)

      {:error, _reason} ->
        # Left pending on purpose: a network blip is not evidence the place
        # does not exist, so the drain gets to try again later.
        place
    end
  end

  @doc """
  Finishes whatever the request-time pass left pending, in the background.

  Fire-and-forget on purpose -- the caller has already responded, and a
  geocoding failure must never surface as a failed agent tool call.
  """
  def drain_async(poet_id, city) do
    # Nothing to drain when geocoding is off, and in :test an unsupervised Task
    # outlives the Ecto sandbox checkout, which surfaces as ownership errors in
    # unrelated suites.
    if Geocoder.enabled?() do
      Task.start(fn -> drain(poet_id, city) end)
    else
      :ok
    end
  end

  def drain(poet_id, city, limit \\ 50) do
    limit
    |> Guide.pending_geocodes()
    |> Enum.filter(&(&1.poet_id == poet_id))
    |> Enum.each(&resolve(&1, city))

    # Wakes any open GuideLive so pins appear without a refresh. Same topic
    # Journal.publish_entry/1 broadcasts on.
    Phoenix.PubSub.broadcast(
      TravelingPoet.PubSub,
      "poet:#{poet_id}",
      {:guide_geocoded, poet_id}
    )
  end

  defp mark_failed(place) do
    case Guide.mark_geocode_failed(place) do
      {:ok, updated} -> updated
      {:error, _} -> place
    end
  end
end
