defmodule TravelingPoetWeb.NativeAuth do
  @moduledoc """
  Google sign-in for the iOS app, which cannot do it the way a browser does.

  Google refuses to run its sign-in inside an embedded web view
  (`disallowed_useragent`), and the app IS a web view. So the app opens the
  ordinary `/auth/google` flow in the system's sign-in sheet
  (ASWebAuthenticationSession) instead, which Google allows. That sheet is
  Safari: it has its own cookie jar, and signing in over there would sign in
  Safari, not the app. The way back across is a handoff:

  1. The app makes a random `verifier`, keeps it, and opens
     `/auth/native/start?challenge=sha256(verifier)` in the sheet. The
     challenge is parked in the SHEET's session.
  2. Google, then `AuthController.callback/2`, all in the sheet. Seeing the
     parked challenge, the callback does not sign the sheet in. It mints a
     60 second token naming the user and the challenge, and redirects to
     `travelpoet://auth?token=...`, which closes the sheet and hands the URL
     to the app.
  3. The app posts token and verifier to `/auth/native/handoff` from the web
     view, and THAT session is signed in.

  The token alone is worth nothing: it is only good together with the
  verifier, which never left the app (the same idea as OAuth's PKCE). That is
  what makes it safe to pass through a URL, and what stops a token minted in
  someone else's sheet from being planted in this app.

  Connecting Drive or Calendar on top of sign-in is the same trip through
  the sheet, except the sheet has to be told who is asking, since it holds no
  session: `connect_token/3` names the user and the feature for 5 minutes.
  """

  alias TravelingPoetWeb.Endpoint

  @scheme "travelpoet"
  @handoff_salt "native-handoff"
  @handoff_max_age 60
  @connect_salt "native-connect"
  @connect_max_age 300

  @doc "The custom URL scheme the sign-in sheet hands its result back on."
  def scheme, do: @scheme

  @doc "A challenge as the app computes it: unpadded base64url of sha256(verifier)."
  def challenge(verifier) when is_binary(verifier),
    do: :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

  @doc "Whether `challenge` looks like one (43 base64url characters)."
  def valid_challenge?(challenge) when is_binary(challenge),
    do: Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, challenge)

  def valid_challenge?(_), do: false

  @doc "The token the sheet sends back: this user, for whoever holds the verifier."
  def handoff_token(user_id, challenge),
    do: Phoenix.Token.sign(Endpoint, @handoff_salt, %{"uid" => user_id, "challenge" => challenge})

  @doc "The user a handoff token names, if it is fresh and the verifier matches."
  def verify_handoff(token, verifier) when is_binary(token) and is_binary(verifier) do
    with {:ok, %{"uid" => user_id, "challenge" => expected}} <-
           Phoenix.Token.verify(Endpoint, @handoff_salt, token, max_age: @handoff_max_age),
         true <- Plug.Crypto.secure_compare(challenge(verifier), expected) do
      {:ok, user_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :verifier_mismatch}
    end
  end

  def verify_handoff(_, _), do: {:error, :invalid}

  @doc "Names who is asking to connect which Google feature, for the sheet."
  def connect_token(user_id, feature, pdf \\ nil) when feature in ["drive", "calendar"] do
    Phoenix.Token.sign(Endpoint, @connect_salt, %{
      "uid" => user_id,
      "feature" => feature,
      "pdf" => pdf
    })
  end

  def verify_connect(token) when is_binary(token),
    do: Phoenix.Token.verify(Endpoint, @connect_salt, token, max_age: @connect_max_age)

  def verify_connect(_), do: {:error, :invalid}

  @doc "Where a finished sign-in sends the sheet: back to the app, with the token."
  def signed_in_url(token), do: "#{@scheme}://auth?" <> URI.encode_query(%{"token" => token})

  @doc "Where a failed sign-in sends the sheet."
  def failed_url, do: "#{@scheme}://auth?" <> URI.encode_query(%{"error" => "failed"})

  @doc """
  Where a finished connect sends the sheet. `to` is the page the app should
  show next, `notice` a code that page turns into the message the browser
  flow would have flashed (`connect_notice/2`): a flash set in the sheet's
  cookie jar would never be seen.
  """
  def connected_url(to, feature, notice) do
    "#{@scheme}://auth/done?" <>
      URI.encode_query(%{"to" => to, "connected" => "#{feature}:#{notice}"})
  end

  @doc "The message for a `connected=feature:notice` param, as `{kind, text}`, or nil."
  def connect_notice(param) when is_binary(param) do
    case String.split(param, ":", parts: 2) do
      [feature, notice] when feature in ["drive", "calendar"] -> notice(feature, notice)
      _ -> nil
    end
  end

  def connect_notice(_), do: nil

  defp notice("calendar", "ok"), do: {:info, "Google Calendar connected. Looking for trips now."}
  defp notice("drive", "ok"), do: {:info, "Connected to Google Drive."}

  defp notice("drive", "ok_saving"),
    do: {:info, "Connected to Google Drive. Saving your PDF there now."}

  defp notice(_, "wrong_account"),
    do: {:error, "Please choose the Google account you sign in with."}

  defp notice("drive", "not_allowed"),
    do: {:error, "Google Drive was not allowed, so nothing was saved."}

  defp notice("calendar", "not_allowed"),
    do: {:error, "Reading your Google Calendar was not allowed, so nothing was read."}

  defp notice("drive", "failed"),
    do: {:error, "Google did not grant Google Drive access. Please try again."}

  defp notice("calendar", "failed"),
    do: {:error, "Google did not grant Google Calendar access. Please try again."}

  defp notice(_, _), do: nil
end
