defmodule TravelingPoetWeb.PageController do
  use TravelingPoetWeb, :controller

  alias TravelingPoet.Poets

  def home(conn, _params) do
    poets =
      Poets.list_public_poets()
      |> Enum.map(fn p ->
        %{
          lat: p.current_lat,
          lng: p.current_lng,
          name: p.name,
          place: p.current_place_name,
          slug: p.slug
        }
      end)

    render(conn, :home, public_poets: poets, layout: false)
  end
end
