defmodule TravelingPoetWeb.PageController do
  use TravelingPoetWeb, :controller

  alias TravelingPoet.Poets

  # Inside the iOS app the home page is a front door, not a pitch: someone
  # signed in goes straight to their journal (or back to onboarding), someone
  # signed out gets the welcome screen. App Review also reads a marketing page
  # as "a website in a wrapper" (guideline 4.2).
  def home(%{assigns: %{native_app: true, current_user: %{} = user}} = conn, _params) do
    if user.onboarding_completed,
      do: redirect(conn, to: ~p"/journal"),
      else: redirect(conn, to: onboarding_path(get_session(conn, :start_place)))
  end

  def home(%{assigns: %{native_app: true}} = conn, _params) do
    # Sign in with Apple needs a nonce that belongs to this session
    {conn, apple_nonce} =
      if TravelingPoet.Apple.configured?(),
        do: TravelingPoetWeb.AppleAuthController.issue_nonce(conn),
        else: {conn, nil}

    render(conn, :welcome,
      start_place: get_session(conn, :start_place),
      apple_nonce: apple_nonce,
      review_login?: TravelingPoetWeb.ReviewLogin.enabled?(),
      layout: false
    )
  end

  def home(conn, _params) do
    my_poet =
      case conn.assigns[:current_user] do
        nil -> nil
        user -> Poets.get_poet_by_user(user.id)
      end

    render(conn, :home,
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
      # The iOS app cannot be redirected into Google (a web view is refused
      # there); it goes back to the welcome screen, which now names the place
      # and whose sign-in button opens the system sheet.
      nil when conn.assigns.native_app ->
        conn
        |> maybe_park_place(place)
        |> redirect(to: ~p"/")

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

  @contact "dibaunaumh@gmail.com"
  # Bumped by hand when either document changes in a way that matters.
  @legal_updated "20 September 2026"

  @doc "The privacy policy, at the url Google's OAuth consent screen points at."
  def privacy(conn, _params) do
    conn
    |> assign(:page_title, "Privacy Policy")
    |> render(:privacy, contact: @contact, updated: @legal_updated)
  end

  @doc "The terms of service, alongside the privacy policy."
  def terms(conn, _params) do
    conn
    |> assign(:page_title, "Terms of Service")
    |> render(:terms, contact: @contact, updated: @legal_updated)
  end

  @doc "Where to get help: the support URL an App Store listing has to carry."
  def support(conn, _params) do
    conn
    |> assign(:page_title, "Support")
    |> render(:support, contact: @contact)
  end

  @doc "Onboarding, with the requested starting place when there is one."
  def onboarding_path(place) when place in [nil, ""], do: ~p"/onboarding"
  def onboarding_path(place), do: ~p"/onboarding?#{[place: place]}"
end
