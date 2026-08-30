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
        entry = Journal.latest_published_entry(p.id)

        %{
          lat: p.current_lat,
          lng: p.current_lng,
          name: p.name,
          place: p.current_place_name,
          slug: p.slug,
          avatar: p.avatar_url,
          entry_url: entry_url(p, entry),
          # The pin follows the poet, but the link goes to the newest entry —
          # which is about wherever they were when they last wrote. Say so
          # when the two have diverged, rather than letting the popup imply
          # the entry is about the place under the pin.
          entry_place: entry_place(p, entry)
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
  defp entry_url(poet, nil), do: "/p/#{poet.slug}"
  defp entry_url(poet, entry), do: "/p/#{poet.slug}/#{entry.entry_date}"

  # Only when it differs from where the pin sits — otherwise the popup would
  # repeat itself.
  defp entry_place(_poet, nil), do: nil
  defp entry_place(_poet, %{place_name: nil}), do: nil
  defp entry_place(%{current_place_name: place}, %{place_name: place}), do: nil
  defp entry_place(_poet, entry), do: entry.place_name
end
