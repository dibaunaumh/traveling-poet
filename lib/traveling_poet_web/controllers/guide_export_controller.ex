defmodule TravelingPoetWeb.GuideExportController do
  @moduledoc """
  The reader's saved places as a KML file, for Google My Maps (card-94):
  import it there and the places travel with them on the trip.
  """
  use TravelingPoetWeb, :controller

  alias TravelingPoet.{Bookmarks, MapsLinks}

  def saved_kml(conn, _params) do
    send_kml(conn, Bookmarks.places(conn.assigns.current_user.id))
  end

  @doc "The same file from a shared Saved list, for the friends it was shared with."
  def shared_kml(conn, %{"token" => token}) do
    case Bookmarks.shared_by(token) do
      nil -> conn |> put_status(404) |> text("Not found")
      owner -> send_kml(conn, Bookmarks.places(owner.id))
    end
  end

  defp send_kml(conn, places) do
    conn
    |> put_resp_content_type("application/vnd.google-earth.kml+xml")
    |> put_resp_header("content-disposition", ~s(attachment; filename="traveling-poet-saved.kml"))
    |> send_resp(200, MapsLinks.kml(places, "Saved on Traveling Poet"))
  end
end
