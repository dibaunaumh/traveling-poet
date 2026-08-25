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
        case Poets.move_to(poet, %{
               lat: lat / 1,
               lng: lng / 1,
               place_name: params["place_name"],
               country_code: params["country_code"]
             }) do
          {:ok, updated} ->
            json(conn, %{
              ok: true,
              place_name: updated.current_place_name,
              arrived_at: updated.arrived_at
            })

          {:error, reason} ->
            conn |> put_status(422) |> json(%{error: inspect(reason)})
        end
    end
  end

  def update(conn, _params) do
    conn |> put_status(422) |> json(%{error: "lat and lng (numbers) are required"})
  end
end
