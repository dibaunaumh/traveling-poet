defmodule TravelingPoetWeb.CalendarController do
  use TravelingPoetWeb, :controller

  alias TravelingPoet.{GoogleAuth, Trips}

  @doc """
  Sends the owner to Google to add read access to their calendar on top of
  sign-in. The intent is parked in the session and picked up by
  AuthController.callback/2 on the way back.
  """
  def connect(conn, _params) do
    user = conn.assigns.current_user

    if Trips.enabled_for?(user) do
      conn
      |> put_session(:google_connect, %{"feature" => "calendar", "user_id" => user.id})
      |> redirect(
        to: "/auth/google?" <> URI.encode_query(GoogleAuth.consent_params(user, :calendar))
      )
    else
      conn
      |> put_flash(:error, "Calendar connections are not open yet.")
      |> redirect(to: ~p"/settings#trips")
    end
  end
end
