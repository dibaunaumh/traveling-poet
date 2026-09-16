defmodule TravelingPoetWeb.MediaController do
  use TravelingPoetWeb, :controller

  alias TravelingPoet.{Journal, Poets}
  alias TravelingPoet.Storage.S3

  @doc """
  Serves a media object (illustration / poet avatar) from Tigris. Media
  belonging to a public poet is world-readable; otherwise only the owner can
  fetch it. Keys are content-unique UUIDs, so long immutable caching is safe.
  """
  def show(conn, %{"id" => id}) do
    with {media_id, ""} <- Integer.parse(id),
         media when not is_nil(media) <- Journal.get_media(media_id),
         poet when not is_nil(poet) <- Poets.get_poet(media.poet_id),
         :ok <- authorize(conn, poet) do
      case S3.download_file(media.s3_key) do
        {:ok, bytes} ->
          conn
          |> put_resp_content_type(media.content_type)
          |> put_resp_header("cache-control", cache_control(poet))
          |> send_resp(200, bytes)

        {:error, _} ->
          send_resp(conn, 502, "media unavailable")
      end
    else
      :forbidden -> send_resp(conn, 403, "forbidden")
      _ -> send_resp(conn, 404, "not found")
    end
  end

  @doc false
  # Public for tests: the render cookie path cannot be exercised through show/2
  # without a bucket.
  def authorize(conn, poet) do
    cond do
      poet.is_public -> :ok
      match?(%{id: id} when id == poet.user_id, conn.assigns[:current_user]) -> :ok
      rendering_this_poet?(conn, poet) -> :ok
      true -> :forbidden
    end
  end

  # The poet's sprite printing the book: its browser holds the render cookie
  # for one PDF of this poet, set by BookController.render_pdf/2.
  defp rendering_this_poet?(conn, poet) do
    conn = Plug.Conn.fetch_cookies(conn)

    case conn.req_cookies[TravelingPoetWeb.BookController.render_cookie()] do
      nil ->
        false

      token ->
        match?(
          {:ok, %{poet_id: id}} when id == poet.id,
          TravelingPoet.Books.verify_render_token(token)
        )
    end
  end

  defp cache_control(%{is_public: true}), do: "public, max-age=31536000, immutable"
  defp cache_control(_), do: "private, max-age=31536000, immutable"
end
