defmodule TravelingPoetWeb.SignIn do
  @moduledoc """
  The last step of every way of signing in: start the session, say hello,
  and send the person to their journal, or to onboarding with the place they
  asked for. Shared by the browser's OAuth callback and the iOS app's
  handoff (and, later, Sign in with Apple).
  """
  use TravelingPoetWeb, :verified_routes

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  alias TravelingPoetWeb.{PageController, UserAuth}

  def establish(conn, user, start_place, greeting_name \\ nil) do
    name = greeting_name || user.name || "there"

    conn
    |> UserAuth.log_in_user(user)
    |> put_flash(:info, "Welcome, #{name}!")
    |> redirect(to: after_login_path(user, start_place))
  end

  defp after_login_path(%{onboarding_completed: true}, _start_place), do: ~p"/journal"
  defp after_login_path(_user, start_place), do: PageController.onboarding_path(start_place)
end
