defmodule TravelingPoetWeb.Api.RouteController do
  @moduledoc """
  Route requests the poet relays from chat, so they become data the daily run
  reads rather than a promise the model has to remember overnight:

    * `hold`: "stay here a while longer" sets `poets.hold_until`.
    * `insert_stop`: "see Catalina before San Diego" adds a stop ahead of the
      next pending one, geocoded through the shared limiter when the agent
      has no coordinates.

  Both answer with the app's current travel decision so the poet can tell
  its companion what will actually happen tomorrow.
  """

  use TravelingPoetWeb, :controller

  alias TravelingPoet.Geocoder.Limiter
  alias TravelingPoet.Poets

  def hold(conn, params) do
    with_poet(conn, fn poet ->
      days = to_int(params["days"]) || 1

      case Poets.hold(poet, days) do
        {:ok, held} ->
          json(conn, %{
            ok: true,
            hold_until: held.hold_until,
            days: days,
            travel: Poets.travel_plan(held)
          })

        {:error, changeset} ->
          conn |> put_status(422) |> json(%{error: errors(changeset)})
      end
    end)
  end

  def insert_stop(conn, %{"place_name" => name} = params)
      when is_binary(name) and name != "" do
    with_poet(conn, fn poet ->
      with {:ok, place} <- resolve_place(String.trim(name), params),
           {:ok, stop} <- Poets.insert_stop_next(poet.id, place) do
        json(conn, %{
          ok: true,
          stop: %{
            id: stop.id,
            position: stop.position,
            place_name: stop.place_name,
            lat: stop.lat,
            lng: stop.lng
          },
          travel: Poets.travel_plan(poet)
        })
      else
        :not_found ->
          conn
          |> put_status(422)
          |> json(%{error: "could not find that place; pass lat and lng with the name"})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn |> put_status(422) |> json(%{error: errors(changeset)})

        {:error, reason} ->
          conn |> put_status(422) |> json(%{error: inspect(reason)})
      end
    end)
  end

  def insert_stop(conn, _params) do
    conn |> put_status(422) |> json(%{error: "place_name is required"})
  end

  # Coordinates from the agent when it has them; otherwise the geocoder. The
  # companion's own name for the place is kept either way; Nominatim's
  # display_name is a postal address, not a name.
  defp resolve_place(name, %{"lat" => lat, "lng" => lng} = params)
       when is_number(lat) and is_number(lng) do
    {:ok, %{place_name: name, lat: lat / 1, lng: lng / 1, country_code: params["country_code"]}}
  end

  defp resolve_place(name, _params) do
    case Limiter.search(name) do
      {:ok, [first | _]} ->
        {:ok,
         %{place_name: name, lat: first.lat, lng: first.lng, country_code: first.country_code}}

      {:ok, []} ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp with_poet(conn, fun) do
    case Poets.get_poet_by_user(conn.assigns.agent_user.id) do
      nil -> conn |> put_status(404) |> json(%{error: "no poet configured"})
      poet -> fun.(poet)
    end
  end

  defp to_int(i) when is_integer(i), do: i
  defp to_int(f) when is_float(f), do: round(f)

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      _ -> nil
    end
  end

  defp to_int(_), do: nil

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
