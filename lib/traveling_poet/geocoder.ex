defmodule TravelingPoet.Geocoder do
  @moduledoc """
  Thin Nominatim (OpenStreetMap) geocoding client. OSM usage policy: identify
  the app via User-Agent, at most 1 req/s — callers must debounce (the
  onboarding wizard geocodes on submit, not per keystroke).
  """

  require Logger

  alias TravelingPoet.Geocoder.{CacheEntry, Limiter}
  alias TravelingPoet.Repo

  @base_url "https://nominatim.openstreetmap.org/search"

  def search(query) when is_binary(query) do
    case Req.get(@base_url,
           # accept-language: en — Nominatim otherwise returns display names in
           # the place's local language/script (京都市…), which beta users
           # couldn't read in their itinerary
           params: [
             q: query,
             format: "json",
             limit: 5,
             addressdetails: 1,
             "accept-language": "en"
           ],
           headers: [{"user-agent", "traveling-poet/0.1 (contact: admin@tpoet.app)"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: results}} when is_list(results) ->
        {:ok, Enum.map(results, &normalize/1)}

      {:ok, %{status: status}} ->
        {:error, "geocoder returned #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp normalize(result) do
    address = result["address"] || %{}

    %{
      place_name: result["display_name"],
      lat: parse_float(result["lat"]),
      lng: parse_float(result["lon"]),
      country_code: address["country_code"] |> upcase_or_nil(),
      # the city behind a street address, for naming a trip's destination
      city: address["city"] || address["town"] || address["village"] || address["municipality"],
      country: address["country"]
    }
  end

  defp parse_float(nil), do: nil
  defp parse_float(str) when is_binary(str), do: String.to_float(str)
  defp parse_float(num) when is_number(num), do: num / 1

  defp upcase_or_nil(nil), do: nil
  defp upcase_or_nil(cc), do: String.upcase(cc)

  @doc """
  Resolves one free-text query to coordinates, through the cache and the
  rate limiter.

  Returns `{:ok, %{lat:, lng:, country_code:}}`, `:not_found`, or
  `{:error, reason}`. Callers must treat all three as survivable: a place the
  geocoder cannot find keeps its listing in the guide, it simply gets no pin.

  Only lat/lng/country_code are taken from the result. Nominatim's
  `display_name` is deliberately discarded here -- the poet's own name for a
  place is better than "Tasca do Chico, 39, Rua do Diario de Noticias,
  Misericordia, Lisboa, ...".
  """
  def locate(query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" ->
        :not_found

      cached = fresh_cache_entry(query) ->
        from_cache(cached)

      not enabled?() ->
        # Test env, or geocoding deliberately switched off. Nominatim needs no
        # API key, so there is no credential to nil out -- this is the switch.
        :not_found

      true ->
        query |> Limiter.search() |> handle_lookup(query)
    end
  end

  def locate(_), do: :not_found

  def enabled?, do: Application.get_env(:traveling_poet, :geocoding_enabled, true)

  defp handle_lookup({:ok, [%{lat: lat, lng: lng} = result | _]}, query)
       when is_number(lat) and is_number(lng) do
    remember(query, result, true)

    {:ok,
     %{
       lat: lat,
       lng: lng,
       country_code: result[:country_code],
       city: result[:city],
       country: result[:country]
     }}
  end

  defp handle_lookup({:ok, _empty_or_unusable}, query) do
    remember(query, %{}, false)
    :not_found
  end

  defp handle_lookup({:error, reason}, _query) do
    # NOT cached: a transient network failure is not evidence the place does
    # not exist, and caching it would strand the place forever.
    Logger.warning("geocode failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp fresh_cache_entry(query) do
    case Repo.get_by(CacheEntry, query_hash: CacheEntry.hash(query)) do
      nil -> nil
      %CacheEntry{found: true} = entry -> entry
      %CacheEntry{} = entry -> if miss_still_fresh?(entry), do: entry, else: nil
    end
  end

  defp miss_still_fresh?(%CacheEntry{looked_up_at: at}) do
    ttl_days = Application.get_env(:traveling_poet, :geocode_miss_ttl_days, 30)
    DateTime.diff(DateTime.utc_now(), at, :day) < ttl_days
  end

  defp from_cache(%CacheEntry{found: true} = entry),
    do:
      {:ok,
       %{
         lat: entry.lat,
         lng: entry.lng,
         country_code: entry.country_code,
         city: entry.city,
         country: entry.country
       }}

  defp from_cache(%CacheEntry{}), do: :not_found

  defp remember(query, result, found?) do
    %CacheEntry{}
    |> CacheEntry.changeset(%{
      query_hash: CacheEntry.hash(query),
      query: query,
      lat: result[:lat],
      lng: result[:lng],
      place_name: result[:place_name],
      country_code: result[:country_code],
      city: result[:city],
      country: result[:country],
      found: found?,
      looked_up_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :query_hash)
  end

  @doc """
  Forgets every cached miss.

  Misses are cached for 30 days, which is right when the miss is real and
  wrong when it was caused by a bad query on our side -- a geocoder fix would
  otherwise be invisible until the TTL expired. Run this after changing how
  queries are built.
  """
  def purge_misses do
    import Ecto.Query, only: [from: 2]
    {count, _} = Repo.delete_all(from(c in CacheEntry, where: c.found == false))
    count
  end

  @doc "A random curated starting location."
  def random_start_location do
    :code.priv_dir(:traveling_poet)
    |> Path.join("data/random_start_locations.json")
    |> File.read!()
    |> Jason.decode!()
    |> Enum.random()
  end

  @doc "The curated currently-reading list (spec Appendix A)."
  def reading_list do
    :code.priv_dir(:traveling_poet)
    |> Path.join("data/reading_list.json")
    |> File.read!()
    |> Jason.decode!()
  end
end
