defmodule TravelingPoetWeb.Plugs.AgentAuth do
  @moduledoc """
  Authenticates the on-sprite OpenClaw agent for the `/api/agent` scope.

  The bearer token is the user's `agent_api_token`, minted at provision time
  with the shape `"<user_id>.<secret>"` — the id prefix makes the DB lookup
  indexed-by-primary-key, and the secret half is compared in constant time.
  This token is delivered to the sprite as TPOET_API_TOKEN in its `.env`,
  and is deliberately distinct from `gateway_token` so the two can be
  rotated independently.
  """

  import Plug.Conn

  alias TravelingPoet.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user} <- verify_token(token) do
      conn
      |> assign(:agent_user, user)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end

  defp verify_token(token) do
    with [id_part, _secret] <- String.split(token, ".", parts: 2),
         {user_id, ""} <- Integer.parse(id_part),
         %{agent_api_token: stored} = user when is_binary(stored) <-
           Accounts.get_user(user_id),
         true <- Plug.Crypto.secure_compare(token, stored) do
      {:ok, user}
    else
      _ -> :error
    end
  end
end
