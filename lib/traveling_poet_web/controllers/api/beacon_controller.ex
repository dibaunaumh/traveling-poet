defmodule TravelingPoetWeb.Api.BeaconController do
  @moduledoc """
  `POST /e`: page events from `assets/js/beacon.js`. The body is a small JSON
  object sent with `navigator.sendBeacon` as text/plain (no preflight, no
  CSRF token to carry), so it is read and decoded here. The visitor id is
  computed server-side; nothing the page sends can choose it. Always 204:
  a beacon has no one to report an error to.
  """
  use TravelingPoetWeb, :controller

  alias TravelingPoet.Analytics

  @max_body 2_048
  @page_events ~w(pageview engage click)

  def create(conn, _params) do
    ua = conn |> get_req_header("user-agent") |> List.first("")

    with false <- Analytics.bot?(ua),
         {:ok, body, conn} <- read_body(conn, length: @max_body),
         {:ok, %{"n" => name} = event} when name in @page_events <- Jason.decode(body) do
      Analytics.record(%{
        visitor: Analytics.visitor_id(conn),
        name: name,
        path: str(event["p"]),
        target: str(event["t"]),
        referrer_host: str(event["r"]),
        utm_source: str(event["us"]),
        utm_campaign: str(event["uc"]),
        duration_ms: int(event["d"]),
        scroll_pct: int(event["s"]),
        viewport: if(event["m"] == true, do: "mobile", else: "desktop")
      })
    end

    send_resp(conn, 204, "")
  end

  defp str(s) when is_binary(s) and s != "", do: s
  defp str(_), do: nil

  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: round(n)
  defp int(_), do: nil
end
