defmodule TravelingPoet.AppLoop.Dispatch do
  @moduledoc """
  Calls an `/api/agent/*` endpoint in-process, as the poet's plugin would
  over HTTP: same router, same `AgentAuth` with the user's agent token, same
  controllers and validation. No socket, no sprite.

  It goes through the router, not the endpoint: production's endpoint forces
  HTTPS and would answer an in-process request with a redirect, and nothing
  else the endpoint does (static files, sessions, body parsing) applies to a
  body that is already a map.

  `shadow: true` marks the request so `AiCTap` does not report it as the
  poet's activity.
  """

  import Plug.Conn

  alias TravelingPoetWeb.Router

  @doc "`{:ok, status, decoded_body}` for one call."
  def call(user, method, path, body, opts \\ []) do
    # Plug.Test reads the query string off the path and merges it into the
    # params with the body (find_reference_photos sends everything there).
    conn =
      Plug.Test.conn(method |> to_string() |> String.upcase(), path, body || %{})
      |> put_req_header("authorization", "Bearer " <> (user.agent_api_token || ""))
      |> put_req_header("accept", "application/json")
      |> put_private(:app_loop_shadow, Keyword.get(opts, :shadow, false))
      |> Router.call(Router.init([]))

    {:ok, conn.status, decode(conn.resp_body)}
  rescue
    e -> {:ok, 500, %{"error" => Exception.message(e)}}
  end

  defp decode(nil), do: nil

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, data} -> data
      _ -> %{"raw" => body}
    end
  end
end
