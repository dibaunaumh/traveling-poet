defmodule TravelingPoet.Hotels do
  @moduledoc """
  Hotel search for a where-to-stay page (card-92), through LiteAPI
  (Nuitée): live prices for the reader's dates, guest rating and
  coordinates in one call. `Hotels.Rank` then orders them by what the app
  knows and a booking site does not: how many of the poet's places are a
  short walk away.

  Udi's decision (2026-10-04): links to book are fine, including ones that
  earn the app a commission, when they serve the reader. Prices are shown
  only as LiteAPI returns them, never estimated.

  Off unless `LITEAPI_KEY` is set (nil in test, where requests go to the
  Req.Test stub `TravelingPoet.Hotels`).
  """
  require Logger

  @api_url "https://api.liteapi.travel/v3.0/hotels/rates"
  # LiteAPI refuses a radius under 1 km; this covers a city's central areas.
  @radius_m 2_500
  @limit 40

  def configured?, do: is_binary(key()) and key() != ""

  @doc """
  Hotels with a live price around a point for these dates, as plain maps:
  id, name, lat, lng, rating (0-10), review_count, stars, address, photo,
  total (the cheapest offer for the whole stay), per_night, currency.
  """
  def search(%{lat: lat, lng: lng}, %Date{} = checkin, %Date{} = checkout, adults \\ 2) do
    nights = Date.diff(checkout, checkin)

    cond do
      not configured?() ->
        {:error, :not_configured}

      nights < 1 ->
        {:error, :bad_dates}

      true ->
        body = %{
          occupancies: [%{adults: adults}],
          currency: currency(),
          guestNationality: "US",
          checkin: Date.to_iso8601(checkin),
          checkout: Date.to_iso8601(checkout),
          latitude: lat,
          longitude: lng,
          radius: @radius_m,
          limit: @limit,
          timeout: 8
        }

        options =
          [
            json: body,
            headers: [{"x-api-key", key()}],
            receive_timeout: 20_000,
            retry: false
          ] ++ Application.get_env(:traveling_poet, :hotels_req_options, [])

        case Req.post(@api_url, options) do
          {:ok, %{status: 200, body: %{} = resp}} ->
            {:ok, parse(resp, nights)}

          {:ok, %{status: status, body: resp}} ->
            Logger.warning("Hotels: LiteAPI returned #{status}: #{inspect(resp, limit: 200)}")
            {:error, {:http, status}}

          {:error, reason} ->
            Logger.warning("Hotels: request failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  @doc false
  def parse(resp, nights) do
    hotels = Map.new(Map.get(resp, "hotels") || [], &{&1["id"], &1})

    (Map.get(resp, "data") || [])
    |> Enum.flat_map(fn rate ->
      with %{} = h <- hotels[rate["hotelId"]],
           {amount, currency} <- cheapest(rate["roomTypes"] || []),
           lat when is_number(lat) <- h["latitude"],
           lng when is_number(lng) <- h["longitude"] do
        [
          %{
            id: h["id"],
            name: h["name"],
            lat: lat,
            lng: lng,
            rating: h["rating"],
            review_count: h["review_count"],
            stars: h["stars"],
            address: h["address"],
            photo: h["thumbnail"] || h["main_photo"],
            total: amount,
            per_night: Float.round(amount / max(nights, 1), 2),
            currency: currency
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp cheapest(room_types) do
    room_types
    |> Enum.flat_map(fn rt ->
      case rt["offerRetailRate"] do
        %{"amount" => a, "currency" => c} when is_number(a) -> [{a * 1.0, c}]
        _ -> []
      end
    end)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
  end

  @doc """
  Where "Book" sends the reader: the white-label booking site set up in
  LiteAPI (`LITEAPI_BOOKING_URL`, a template with {hotel_id}, {checkin},
  {checkout}, {adults}). Nil until it is set, and then no link is shown.
  """
  def booking_url(%{id: id}, %Date{} = checkin, %Date{} = checkout, adults) do
    case Application.get_env(:traveling_poet, :liteapi_booking_url) do
      template when is_binary(template) and template != "" ->
        template
        |> String.replace("{hotel_id}", URI.encode_www_form(to_string(id)))
        |> String.replace("{checkin}", Date.to_iso8601(checkin))
        |> String.replace("{checkout}", Date.to_iso8601(checkout))
        |> String.replace("{adults}", to_string(adults))

      _ ->
        nil
    end
  end

  defp key, do: Application.get_env(:traveling_poet, :liteapi_key)
  defp currency, do: Application.get_env(:traveling_poet, :liteapi_currency) || "EUR"
end
