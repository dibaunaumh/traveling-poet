defmodule TravelingPoetWeb.Api.ArtifactController do
  use TravelingPoetWeb, :controller

  alias TravelingPoet.Accounts
  alias TravelingPoet.Artifacts
  alias TravelingPoetWeb.SessionToken

  require Logger

  def show(conn, params) do
    with {:ok, user} <- authenticate(conn, params),
         {:ok, sprite_name} <- ensure_sprite(user),
         {:ok, rel_path} <- Artifacts.validate_path(params["path"]),
         {:ok, local_path} <- Artifacts.ensure_cached(sprite_name, rel_path) do
      conn
      |> put_resp_content_type(MIME.from_path(rel_path))
      |> put_resp_header("content-disposition", disposition(rel_path, params["download"]))
      |> put_resp_header("cache-control", "private, max-age=60")
      |> send_file(200, local_path)
    else
      {:error, :unauthenticated} ->
        error(conn, :unauthorized, "unauthenticated")

      {:error, :no_sprite} ->
        error(conn, :forbidden, "no_sprite")

      {:error, :invalid_path} ->
        error(conn, :bad_request, "invalid_path")

      {:error, :not_found} ->
        error(conn, :not_found, "not_found")

      {:error, :too_large} ->
        conn
        |> put_status(:request_entity_too_large)
        |> json(%{error: "too_large", max_bytes: Artifacts.max_bytes()})

      {:error, {:sprites, reason}} ->
        Logger.error("ArtifactController sprites error: #{inspect(reason)}")
        error(conn, :bad_gateway, "sprites_unavailable")
    end
  end

  defp authenticate(conn, params) do
    cond do
      user_id = get_session(conn, :user_id) ->
        load_user(user_id)

      token = params["token"] ->
        case SessionToken.verify(token) do
          {:ok, user_id} -> load_user(user_id)
          _ -> {:error, :unauthenticated}
        end

      true ->
        {:error, :unauthenticated}
    end
  end

  defp load_user(user_id) do
    case Accounts.get_user(user_id) do
      nil -> {:error, :unauthenticated}
      user -> {:ok, user}
    end
  end

  defp ensure_sprite(%{sprite_name: name}) when is_binary(name) and name != "", do: {:ok, name}
  defp ensure_sprite(_), do: {:error, :no_sprite}

  defp disposition(rel_path, download) when download in ["1", "true"] do
    ~s(attachment; filename="#{Path.basename(rel_path)}")
  end

  defp disposition(_rel_path, _), do: "inline"

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{error: code})
  end
end
