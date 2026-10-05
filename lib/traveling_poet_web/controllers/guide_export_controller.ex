defmodule TravelingPoetWeb.GuideExportController do
  @moduledoc """
  The reader's saved places as a KML file, for Google My Maps (card-94):
  import it there and the places travel with them on the trip.
  """
  use TravelingPoetWeb, :controller

  alias TravelingPoet.{Bookmarks, MapsLinks}

  def saved_kml(conn, _params) do
    user = conn.assigns.current_user

    places =
      user.id
      |> Bookmarks.list()
      |> Enum.filter(&(&1.bookmark.kind == "place"))
      |> Enum.map(& &1.item)

    conn
    |> put_resp_content_type("application/vnd.google-earth.kml+xml")
    |> put_resp_header("content-disposition", ~s(attachment; filename="traveling-poet-saved.kml"))
    |> send_resp(200, MapsLinks.kml(places, "Saved on Traveling Poet"))
  end
end
