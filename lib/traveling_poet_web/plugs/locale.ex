defmodule TravelingPoetWeb.Plugs.Locale do
  @moduledoc """
  Picks the interface language for a request (card-101).

  A signed-in reader always gets their own `users.locale`. Anyone else, in
  order: `?lang=`, the language already in their session, their
  `Accept-Language`, English. The answer goes into the session so the
  LiveView socket sees the same one (`UserAuth.mount_current_user/2`), but
  only when it changed: a cookie store re-sends the cookie on every change
  (see `UserAuth.keep_session_fresh/2`).

  Runs after `:fetch_current_user`.
  """

  import Plug.Conn

  alias TravelingPoet.Locale

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    locale = pick(conn)

    Gettext.put_locale(TravelingPoetWeb.Gettext, locale)

    conn
    |> assign(:locale, locale)
    |> assign(:dir, Locale.dir(locale))
    |> remember(locale)
  end

  defp pick(conn) do
    case conn.assigns[:current_user] do
      %{locale: locale} when is_binary(locale) ->
        Locale.normalize(locale) || Locale.default()

      _ ->
        Locale.normalize(conn.query_params["lang"]) ||
          Locale.normalize(get_session(conn, :locale)) ||
          conn
          |> get_req_header("accept-language")
          |> List.first()
          |> Locale.from_accept_language() ||
          Locale.default()
    end
  end

  defp remember(conn, locale) do
    if get_session(conn, :locale) == locale,
      do: conn,
      else: put_session(conn, :locale, locale)
  end
end
