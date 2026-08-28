defmodule TravelingPoetWeb.PageController do
  use TravelingPoetWeb, :controller

  alias TravelingPoet.Journal
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
          slug: p.slug,
          avatar: p.avatar_url,
          entry_url: latest_entry_url(p)
        }
      end)

    render(conn, :home,
      public_poets: poets,
      my_poet: my_poet,
      signed_out?: is_nil(conn.assigns[:current_user]),
      layout: false
    )
  end

  # Deep-link straight to the newest published entry when there is one; the
  # journal index (which redirects to the newest) is the fallback.
  defp latest_entry_url(poet) do
    case Journal.latest_published_entry(poet.id) do
      nil -> "/p/#{poet.slug}"
      entry -> "/p/#{poet.slug}/#{entry.entry_date}"
    end
  end
end
