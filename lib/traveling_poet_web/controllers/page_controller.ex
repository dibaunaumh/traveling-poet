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

    latest = Map.new(public, fn p -> {p.id, Journal.latest_published_entry(p.id)} end)

    poets =
      Enum.map(public, fn p ->
        entry = latest[p.id]

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

    # The open notebook under the map: every public poet's newest page, in the
    # same order as the pins, so the map can turn the pages.
    spreads =
      public
      |> Enum.map(fn p -> {p, latest[p.id]} end)
      |> Enum.reject(fn {_p, entry} -> is_nil(entry) end)
      |> Enum.map(fn {p, entry} -> spread(p, Journal.preload_entry(entry)) end)

    render(conn, :home,
      public_poets: poets,
      spreads: spreads,
      anonymous_poets: Enum.map(private, &Poets.Showcase.blurred_point/1),
      poets_on_map: length(public) + length(private),
      my_poet: my_poet,
      signed_out?: is_nil(conn.assigns[:current_user]),
      layout: false
    )
  end

  @doc """
  The hero's "Where should your poet set out from?" box. A signed-out visitor
  goes through Google sign-in first, so the place is parked in the session
  and picked up by `AuthController` on the way back; someone already signed in
  lands on onboarding with the place pre-filled, or on their journal if their
  poet is already on the road.
  """
  def start(conn, params) do
    place = params |> Map.get("place", "") |> String.trim() |> String.slice(0, 120)

    case conn.assigns[:current_user] do
      nil ->
        conn
        |> maybe_park_place(place)
        |> redirect(to: ~p"/auth/google")

      user ->
        if user.onboarding_completed and Poets.get_poet_by_user(user.id) do
          redirect(conn, to: ~p"/journal")
        else
          redirect(conn, to: onboarding_path(place))
        end
    end
  end

  defp maybe_park_place(conn, ""), do: conn
  defp maybe_park_place(conn, place), do: put_session(conn, :start_place, place)

  @doc "Onboarding, with the requested starting place when there is one."
  def onboarding_path(place) when place in [nil, ""], do: ~p"/onboarding"
  def onboarding_path(place), do: ~p"/onboarding?#{[place: place]}"

  # Left page: the words (title, description, poem). Right page: the drawing
  # and the practical notes. A page with no drawing of its own borrows the
  # entry's first unattached illustration, as the journal does.
  defp spread(poet, entry) do
    media =
      entry.sections
      |> Enum.map(& &1.media_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Journal.get_media/1)
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.id, &1})

    {words, rest} = Enum.split_with(entry.sections, &(&1.kind in ["description", "poem"]))
    {drawings, notes} = Enum.split_with(rest, &(&1.kind == "illustration"))

    drawings =
      if Enum.any?(drawings, &media[&1.media_id]),
        do: Enum.filter(drawings, &media[&1.media_id]),
        else: Enum.take(Journal.unattached_illustrations(entry, entry.sections), 1)

    %{
      poet: poet,
      entry: entry,
      media: media,
      words: words,
      drawings: drawings,
      notes: notes,
      url: entry_url(poet, entry)
    }
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
