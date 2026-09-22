defmodule TravelingPoetWeb.AppleAuthController do
  @moduledoc """
  Sign in with Apple, from the iOS app.

  Apple's sheet is native: the app shows it and the page gets an identity
  token and a one-time authorization code back through the bridge
  (`PoetNative.signInWithApple`). The page posts them here from the web
  view, so the session that gets signed in is the web view's own, with no
  handoff needed (unlike Google; see `NativeAuth`).

  The nonce ties the token to this session: the welcome screen put a random
  one in the session and gave the page its hash to hand to Apple, and Apple
  copies that into the token. It is read and dropped here, so a token works
  once, in the session that asked for it.
  """
  use TravelingPoetWeb, :controller

  require Logger

  alias TravelingPoet.{Accounts, Analytics, Apple}
  alias TravelingPoet.Apple.IdentityToken
  alias TravelingPoetWeb.SignIn

  @doc "A fresh nonce for this session; returns the hash the page gives to Apple."
  def issue_nonce(conn) do
    raw = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    {put_session(conn, :apple_nonce, raw), IdentityToken.hashed_nonce(raw)}
  end

  def native(conn, %{"identity_token" => token} = params) do
    raw_nonce = get_session(conn, :apple_nonce)
    start_place = get_session(conn, :start_place)
    conn = delete_session(conn, :apple_nonce)

    with true <- Apple.configured?() || {:error, :not_configured},
         {:ok, identity} <- IdentityToken.verify(token, raw_nonce),
         new? = is_nil(Accounts.get_user_by_apple_id(identity.sub)),
         {:ok, user} <- Accounts.find_or_create_from_oauth(:apple, user_info(identity, params)) do
      user = keep_refresh_token(user, params["authorization_code"])

      Analytics.record(%{
        name: if(new?, do: "signup", else: "login"),
        visitor: Analytics.visitor_id(conn),
        user_id: user.id
      })

      SignIn.establish(conn, user, start_place)
    else
      {:error, reason} ->
        Logger.warning("Sign in with Apple refused: #{refusal(reason)}")

        conn
        |> put_flash(:error, "That sign-in did not go through. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  def native(conn, _params), do: redirect(conn, to: ~p"/")

  # A changeset carries the person's email; the log gets the field names only.
  defp refusal(%Ecto.Changeset{errors: errors}), do: "invalid #{inspect(Keyword.keys(errors))}"
  defp refusal(reason), do: inspect(reason)

  # A "Hide My Email" relay address is unique to this app, so it can never be
  # the address of an existing account; saying so keeps it from ever being
  # used to link one.
  defp user_info(identity, params) do
    %{
      "sub" => identity.sub,
      "email" => identity.email,
      "email_verified" => identity.email_verified and not identity.private_relay,
      "name" => full_name(params)
    }
  end

  # Apple sends the name once, on the very first sign-in, and not in the
  # token: the app passes it along beside it.
  defp full_name(params) do
    [params["given_name"], params["family_name"]]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map_join(" ", &String.trim/1)
    |> String.slice(0, 120)
    |> case do
      "" -> nil
      name -> name
    end
  end

  # Needed only to revoke the grant when the account is deleted. Signing in
  # must not fail because Apple's token endpoint did.
  defp keep_refresh_token(user, code) do
    with {:ok, refresh_token} <- Apple.exchange_code(code),
         {:ok, user} <- Accounts.update_user(user, %{apple_refresh_token: refresh_token}) do
      user
    else
      other ->
        Logger.warning("Apple code exchange failed for user #{user.id}: #{inspect(other)}")
        user
    end
  end
end
