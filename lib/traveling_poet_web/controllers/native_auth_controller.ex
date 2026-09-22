defmodule TravelingPoetWeb.NativeAuthController do
  @moduledoc """
  The iOS app's way through Google sign-in and Google feature consent. The
  how and why is in `TravelingPoetWeb.NativeAuth`; `start` and `connect` run
  in the system sign-in sheet, `connect_url` and `handoff` in the app's own
  web view.
  """
  use TravelingPoetWeb, :controller

  alias TravelingPoet.{Accounts, GoogleAuth, GoogleDrive, Trips}
  alias TravelingPoetWeb.{NativeAuth, SignIn}

  @doc "In the sheet: remember the app's challenge, then on to Google."
  def start(conn, %{"challenge" => challenge}) do
    if NativeAuth.valid_challenge?(challenge) do
      conn
      |> put_session(:native_auth, %{"challenge" => challenge})
      |> redirect(to: ~p"/auth/google")
    else
      redirect(conn, external: NativeAuth.failed_url())
    end
  end

  def start(conn, _params), do: redirect(conn, external: NativeAuth.failed_url())

  @doc """
  In the app: the address to open in the sheet to connect a Google feature.
  Asked for at the moment of the tap, so the token in it is always fresh.
  """
  def connect_url(conn, %{"feature" => feature} = params) when feature in ["drive", "calendar"] do
    user = conn.assigns.current_user
    token = NativeAuth.connect_token(user.id, feature, params["pdf"])
    json(conn, %{url: url(~p"/auth/native/connect?#{[token: token]}")})
  end

  def connect_url(conn, _params), do: conn |> put_status(400) |> json(%{error: "unknown feature"})

  @doc """
  In the sheet: who is asking and for what comes from the token (the sheet
  has no session of its own), then on to Google's consent screen exactly as
  `CalendarController.connect/2` and `BookController.connect_drive/2` do.
  """
  def connect(conn, %{"token" => token}) do
    with {:ok, %{"uid" => user_id, "feature" => feature, "pdf" => pdf}} <-
           NativeAuth.verify_connect(token),
         %{} = user <- Accounts.get_user(user_id),
         {:ok, consent} <- consent_params(user, feature) do
      conn
      |> put_session(:native_auth, %{"connect" => true})
      |> put_session(:google_connect, %{"feature" => feature, "pdf" => pdf, "user_id" => user.id})
      |> redirect(to: "/auth/google?" <> URI.encode_query(consent))
    else
      _ -> redirect(conn, external: NativeAuth.failed_url())
    end
  end

  def connect(conn, _params), do: redirect(conn, external: NativeAuth.failed_url())

  defp consent_params(user, "drive"), do: {:ok, GoogleDrive.consent_params(user)}

  defp consent_params(user, "calendar") do
    if Trips.enabled_for?(user),
      do: {:ok, GoogleAuth.consent_params(user, :calendar)},
      else: {:error, :not_enabled}
  end

  @doc """
  In the app: trade the sheet's token, plus the verifier only this app holds,
  for a session. A form POST, so it is CSRF-protected like any other: nobody
  can sign this web view into an account of their choosing from outside.
  """
  def handoff(conn, %{"token" => token, "verifier" => verifier}) do
    with {:ok, user_id} <- NativeAuth.verify_handoff(token, verifier),
         %{} = user <- Accounts.get_user(user_id) do
      # Parked by the destination box before the sheet opened; log_in_user
      # clears the session, so read it first.
      SignIn.establish(conn, user, get_session(conn, :start_place))
    else
      _ ->
        conn
        |> put_flash(:error, "That sign-in did not go through. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  def handoff(conn, _params), do: redirect(conn, to: ~p"/")
end
