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

    {public, private} =
      Poets.list_poets_on_the_road() |> Enum.split_with(& &1.is_public)

    poets =
      Enum.map(public, fn p ->
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
      anonymous_poets: Enum.map(private, &blurred_point/1),
      poets_on_map: length(public) + length(private),
      my_poet: my_poet,
      signed_out?: is_nil(conn.assigns[:current_user]),
      layout: false
    )
  end

  # A private poet contributes a pin and nothing else: no name, slug, avatar or
  # place, and coordinates rounded to ~10km so the dot says "somewhere around
  # here" rather than pointing at a street.
  defp blurred_point(poet) do
    %{lat: Float.round(poet.current_lat, 1), lng: Float.round(poet.current_lng, 1)}
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
