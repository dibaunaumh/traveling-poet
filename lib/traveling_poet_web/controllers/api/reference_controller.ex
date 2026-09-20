defmodule TravelingPoetWeb.Api.ReferenceController do
  use TravelingPoetWeb, :controller

  alias TravelingPoet.Commons

  @doc """
  `GET /api/agent/reference_photos?query=&lat=&lng=&radius_m=&limit=`

  Wikimedia Commons photos to draw from, found app-side for free instead of
  through a paid web search. See `TravelingPoet.Commons`.
  """
  def photos(conn, params) do
    opts =
      [
        lat: number(params["lat"]),
        lng: number(params["lng"]),
        radius_m: number(params["radius_m"]),
        limit: number(params["limit"])
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Commons.search(params["query"], opts) do
      {:ok, []} ->
        json(conn, %{
          photos: [],
          note:
            "Nothing on Commons for that. Try the place's own name without extra words, " <>
              "or pass lat/lng to see what was photographed nearby."
        })

      {:ok, photos} ->
        json(conn, %{
          photos: photos,
          note:
            "Cite page_url (the file page), never thumb_url. Only cite a photo that shows " <>
              "what you drew."
        })

      {:error, "a query or lat/lng is required" = reason} ->
        conn |> put_status(422) |> json(%{error: reason})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: reason})
    end
  end

  defp number(n) when is_number(n), do: n

  defp number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} -> f
      _ -> nil
    end
  end

  defp number(_), do: nil
end
