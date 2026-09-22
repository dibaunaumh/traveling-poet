defmodule TravelingPoetWeb.Plugs.NativeApp do
  @moduledoc """
  Tells the iOS app from a browser.

  The app is a web view around this site (the `traveling-poet-ios` repo), and
  it signs its requests with a suffix on the User-Agent:
  `TravelingPoetiOS/<version>`. A few things have to differ in there. Apple
  does not allow a Stripe checkout for credits inside an app, Google refuses
  to run its sign-in in an embedded web view, and a web view has no Web Push.
  Everything that branches on that reads `native_app` (assigned here for
  controllers, and in `UserAuth.mount_current_user/2` for LiveViews, which see
  the same header through the socket's `connect_info`).

  Anyone can send this header. It only ever takes options away (no card
  checkout, no web sign-in links), so a spoofed one gains nothing.
  """

  import Plug.Conn

  @suffix ~r{\bTravelingPoetiOS/(\d+(?:\.\d+)*)}

  def init(opts), do: opts

  def call(conn, _opts) do
    assign(conn, :native_app, conn |> get_req_header("user-agent") |> List.first() |> native?())
  end

  @doc "Whether a User-Agent string is the iOS app's."
  def native?(user_agent) when is_binary(user_agent), do: Regex.match?(@suffix, user_agent)
  def native?(_), do: false
end
