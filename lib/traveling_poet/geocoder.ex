defmodule TravelingPoet.Geocoder do
  @moduledoc """
  Thin Nominatim (OpenStreetMap) geocoding client. OSM usage policy: identify
  the app via User-Agent, at most 1 req/s — callers must debounce (the
  onboarding wizard geocodes on submit, not per keystroke).
  """

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
    %{
      place_name: result["display_name"],
      lat: parse_float(result["lat"]),
      lng: parse_float(result["lon"]),
      country_code: get_in(result, ["address", "country_code"]) |> upcase_or_nil()
    }
  end

  defp parse_float(nil), do: nil
  defp parse_float(str) when is_binary(str), do: String.to_float(str)
  defp parse_float(num) when is_number(num), do: num / 1

  defp upcase_or_nil(nil), do: nil
  defp upcase_or_nil(cc), do: String.upcase(cc)

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
