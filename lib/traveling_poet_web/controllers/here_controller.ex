defmodule TravelingPoetWeb.HereController do
  @moduledoc """
  Where the reader's device says they are (card-78), posted by
  `assets/js/here.js` while a page is open, and only for a reader who
  switched it on in Settings. A plain route, not a LiveView event, so every
  signed-in page can report without each LiveView handling it.
  """

  use TravelingPoetWeb, :controller

  alias TravelingPoet.NearHome.Away

  def update(conn, params) do
    with {:ok, lat} <- number(params["lat"]),
         {:ok, lng} <- number(params["lng"]),
         {:ok, status} <- Away.report(conn.assigns.current_user, lat, lng) do
      json(conn, %{
        away: status.away?,
        place:
          status.here && Away.display_name(status.here.name, status.here.lat, status.here.lng),
        looking: status.looking?
      })
    else
      {:error, :off} -> conn |> put_status(409) |> json(%{error: "off"})
      _ -> conn |> put_status(422) |> json(%{error: "invalid"})
    end
  end

  defp number(value) when is_number(value), do: {:ok, value / 1}

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp number(_), do: :error
end
