defmodule TravelingPoetWeb.Api.LocationController do
  use TravelingPoetWeb, :controller

  alias TravelingPoet.Poets

  def update(conn, %{"lat" => lat, "lng" => lng} = params)
      when is_number(lat) and is_number(lng) do
    user = conn.assigns.agent_user

    case Poets.get_poet_by_user(user.id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "no poet configured"})

      poet ->
        target = %{
          lat: lat / 1,
          lng: lng / 1,
          place_name: params["place_name"],
          country_code: params["country_code"]
        }

        # A stop the companion planned or asked for may be anywhere; the
        # poet's own choice must be somewhere it has not been.
        case !is_integer(params["itinerary_stop_id"]) && Poets.earlier_stay(poet.id, target) do
          %{} = stay -> refuse_return(conn, stay)
          _ -> move(conn, poet, target, params)
        end
    end
  end

  def update(conn, _params) do
    conn |> put_status(422) |> json(%{error: "lat and lng (numbers) are required"})
  end

  defp refuse_return(conn, stay) do
    when_ =
      if stay.departed_at == nil,
        do: "you are there now",
        else: "you stayed there from #{DateTime.to_date(stay.arrived_at)}"

    conn
    |> put_status(422)
    |> json(%{
      error: "already visited",
      already_visited: %{
        place_name: stay.place_name,
        arrived_on: DateTime.to_date(stay.arrived_at)
      },
      note:
        "#{stay.place_name}: #{when_}. You did not move. A journey moves on: pick a place " <>
          "that is not in journey.visited and not within 10 km of one, and call " <>
          "update_location again. If every nearby place is taken, go further."
    })
  end

  defp move(conn, poet, target, params) do
    case Poets.move_to(poet, target) do
      {:ok, updated} ->
        stop_visited = maybe_mark_stop_visited(poet, params["itinerary_stop_id"])

        json(conn, %{
          ok: true,
          place_name: updated.current_place_name,
          arrived_at: updated.arrived_at,
          itinerary_stop_visited: stop_visited
        })

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  defp maybe_mark_stop_visited(poet, stop_id) when is_integer(stop_id) do
    case Poets.mark_stop_visited(poet.id, stop_id) do
      {:ok, _} -> stop_id
      _ -> nil
    end
  end

  defp maybe_mark_stop_visited(_poet, _), do: nil
end
