defmodule TravelingPoet.Geocoder.Destinations do
  @moduledoc """
  Reads what a visitor typed in a destination box (card-97). The home page
  suggests "Lisbon, Kyoto, Oaxaca…", so people type a list, and Nominatim
  given a list answers with noise or nothing ("Lisbon, Porto" is an office
  park in Lisbon; "Rome, Florence, Venice" is nothing). But a comma is also
  how people qualify one place: "Paris, Texas", "Lisbon, Portugal".

  `resolve/2` tells the two apart by what the LAST part is. A country, state
  or region after the comma is a qualifier, so the whole string is one
  place. A city or town after the comma makes the string a route, and every
  part is looked up on its own, in order. Each lookup is one Nominatim call
  through `Geocoder.Limiter` (1 req/s), so a route of three costs three
  seconds; callers run it off the LiveView (`start_async`).

  Returns:

    * `{:place, results}`: one place, the result list as `Geocoder.search/1`
      gives it (top first; wander mode auto-picks the top).
    * `{:route, stops, missing}`: two or more places in order (`stops`, one
      result each) and the names that found nothing (`missing`).
    * `{:none, query}`: nothing found for anything.
    * `{:error, reason}`: the geocoder was unreachable.
  """

  alias TravelingPoet.Geocoder.Limiter

  # Nominatim `addresstype`s that qualify a place rather than name one.
  @qualifiers ~w(country state region province county state_district district)

  # Parts of a route separated by a comma or a semicolon.
  @separators ~r/\s*[,;]\s*/

  @doc """
  Whether a geocoder result names a whole country or region rather than a
  town. A poet cannot stand in "Thailand": its pin would be the country's
  centre point and its pages would say "Written from Thailand".
  """
  def region?(%{kind: kind}) when kind in @qualifiers, do: true
  def region?(_), do: false

  @doc "The parts of a destination string, trimmed, empties dropped."
  def parts(query) when is_binary(query) do
    query
    |> String.split(@separators)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "See the moduledoc. `search` is `Limiter.search/1` unless a test says otherwise."
  def resolve(query, search \\ search_fun()) when is_binary(query) do
    query = String.trim(query)

    case parts(query) do
      [] ->
        {:none, query}

      [_one] ->
        one_place(query, search)

      parts ->
        last = List.last(parts)

        case search.(last) do
          {:error, reason} ->
            {:error, reason}

          {:ok, [%{kind: kind} = top | _]} when kind in @qualifiers ->
            # "Paris, Texas": the whole string names one place. Only when
            # Nominatim has nothing for it is the list read as a route.
            case one_place(query, search) do
              {:place, _} = found -> found
              _ -> route(parts, %{last => top}, search)
            end

          {:ok, [top | _]} ->
            route(parts, %{last => top}, search)

          {:ok, []} ->
            route(parts, %{last => nil}, search)
        end
    end
  end

  defp one_place(query, search) do
    case search.(query) do
      {:ok, []} -> {:none, query}
      {:ok, results} -> {:place, results}
      {:error, reason} -> {:error, reason}
    end
  end

  # Every part on its own, in order. A part that names a country is not a
  # stop (it is "Lisbon, Portugal" with the whole-string lookup failed), and
  # a route that boils down to one place is that place.
  defp route(parts, known, search) do
    {stops, missing, error} =
      Enum.reduce(parts, {[], [], nil}, fn part, {stops, missing, error} ->
        found =
          case Map.fetch(known, part) do
            {:ok, top} -> {:ok, top}
            :error -> top_of(search.(part))
          end

        case found do
          {:ok, %{kind: "country"}} -> {stops, missing, error}
          {:ok, %{} = top} -> {[top | stops], missing, error}
          {:ok, nil} -> {stops, [part | missing], error}
          {:error, reason} -> {stops, missing, error || reason}
        end
      end)

    stops = Enum.reverse(stops)
    missing = Enum.reverse(missing)

    cond do
      stops == [] and error -> {:error, error}
      stops == [] -> {:none, Enum.join(parts, ", ")}
      length(stops) == 1 and missing == [] -> {:place, stops}
      true -> {:route, stops, missing}
    end
  end

  defp top_of({:ok, [top | _]}), do: {:ok, top}
  defp top_of({:ok, []}), do: {:ok, nil}
  defp top_of({:error, reason}), do: {:error, reason}

  @doc """
  One place search, the way every reader-facing search box runs it: through
  `Geocoder.Limiter`, or `:destination_search` when a test swaps it in.
  """
  def search(query), do: search_fun().(query)

  defp search_fun,
    do: Application.get_env(:traveling_poet, :destination_search, &Limiter.search/1)
end
