defmodule TravelingPoetWeb.Plugs.CacheBodyReader do
  @moduledoc """
  `Plug.Parsers` body reader that keeps the raw request body in
  `conn.assigns.raw_body` for `/webhooks/*` — Stripe signatures are computed
  over the exact bytes, which the JSON parser otherwise consumes.
  """

  def read_body(conn, opts) do
    with {:ok, body, conn} <- read_all(conn, opts, []) do
      conn =
        if String.starts_with?(conn.request_path, "/webhooks/"),
          do: Plug.Conn.assign(conn, :raw_body, body),
          else: conn

      {:ok, body, conn}
    end
  end

  defp read_all(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary([acc, chunk]), conn}
      {:more, chunk, conn} -> read_all(conn, opts, [acc, chunk])
      {:error, _} = err -> err
    end
  end
end
