defmodule TravelingPoetWeb.PageController do
  use TravelingPoetWeb, :controller

  alias TravelingPoet.Poets

  def home(conn, _params) do
    my_poet =
      case conn.assigns[:current_user] do
        nil -> nil
        user -> Poets.get_poet_by_user(user.id)
      end

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

    render(conn, :home,
      public_poets: poets,
      my_poet: my_poet,
      signed_out?: is_nil(conn.assigns[:current_user]),
      layout: false
    )
  end
end
