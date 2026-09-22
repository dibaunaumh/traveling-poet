defmodule TravelingPoetWeb.UserAuth do
  @moduledoc """
  Authentication helpers for plugs and LiveViews.
  """

  use TravelingPoetWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias TravelingPoet.Accounts
  alias TravelingPoetWeb.Plugs.NativeApp

  @doc """
  Logs the user in. Renews the session ID and clears the whole session to
  avoid fixation attacks.
  """
  def log_in_user(conn, user) do
    conn
    |> renew_session()
    |> put_session(:user_id, user.id)
    |> put_session(:live_socket_id, "users_sessions:#{user.id}")
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  @doc """
  Logs the user out and clears all session data.
  """
  def log_out_user(conn) do
    if live_socket_id = get_session(conn, :live_socket_id) do
      TravelingPoetWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session.
  """
  def fetch_current_user(conn, _opts) do
    user_id = get_session(conn, :user_id)
    user = user_id && user_id |> Accounts.get_user() |> Accounts.touch_last_seen()

    conn
    |> assign(:current_user, user)
    |> keep_session_fresh(user)
  end

  # A cookie store only sends a new cookie when the session changes, so a
  # `max_age` alone would sign people out 180 days after they signed IN,
  # however often they came back. Touching one key a week restarts the clock.
  @refresh_after_seconds 7 * 24 * 60 * 60

  defp keep_session_fresh(conn, nil), do: conn

  defp keep_session_fresh(conn, _user) do
    now = System.system_time(:second)

    case get_session(conn, :refreshed_at) do
      at when is_integer(at) and now - at < @refresh_after_seconds -> conn
      _ -> put_session(conn, :refreshed_at, now)
    end
  end

  @doc """
  Ensures the user is authenticated; redirects home otherwise.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  @doc """
  Used for routes that require the user to NOT be authenticated.
  """
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
      |> redirect(to: ~p"/journal")
      |> halt()
    else
      conn
    end
  end

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/")

      {:halt, socket}
    end
  end

  def on_mount(:ensure_admin, _params, session, socket) do
    socket = mount_current_user(socket, session)

    case socket.assigns[:current_user] do
      %{is_admin: true} ->
        {:cont, socket}

      _ ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  defp mount_current_user(socket, session) do
    socket =
      Phoenix.Component.assign_new(socket, :current_user, fn ->
        if user_id = session["user_id"] do
          user_id |> Accounts.get_user() |> Accounts.touch_last_seen()
        end
      end)

    # Header pill: only surfaces when the balance is low, so a fresh read on
    # every mount is the whole cost of showing it.
    socket =
      Phoenix.Component.assign_new(socket, :credits_low, fn ->
        credits_low?(socket.assigns[:current_user])
      end)

    # The iOS app, by its User-Agent (see Plugs.NativeApp). On the first
    # render this comes from the plug's assign; over the socket, from the
    # `:user_agent` connect_info.
    Phoenix.Component.assign_new(socket, :native_app, fn ->
      socket |> Phoenix.LiveView.get_connect_info(:user_agent) |> NativeApp.native?()
    end)
  end

  @doc "Whether the signed-in user is running low on credits (nil-safe)."
  def credits_low?(nil), do: false

  def credits_low?(user) do
    TravelingPoet.Credits.low?(user, TravelingPoet.Poets.get_poet_by_user(user.id))
  end
end
