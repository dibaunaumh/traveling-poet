defmodule TravelingPoetWeb.ItemController do
  @moduledoc """
  The public face of a Spaces item (kb-002 phase 3): `/items/:slug` as a
  page with its JSON-LD embedded, `/items/:slug/jsonld` as the document
  alone, and `/items.geojson` as the mapped public items with filters. All
  of it reads through `Spaces.Public`, so a private poet's finds never
  appear, and a slug that was merged away redirects to the item that
  absorbed it, for good.
  """
  use TravelingPoetWeb, :controller

  alias TravelingPoet.MapsLinks
  alias TravelingPoet.Spaces.{JsonLd, Public}

  def show(conn, %{"slug" => slug}) do
    case Public.lookup(slug) do
      {:ok, item} ->
        facts = Public.facts(item)

        conn
        |> assign(:page_title, item.name)
        |> render(:show,
          facts: facts,
          json_ld: Jason.encode!(JsonLd.build(facts, base_url()), escape: :html_safe),
          maps_url:
            MapsLinks.google_url(%{name: item.name, address: nil, lat: item.lat, lng: item.lng}),
          kind_word: kind_word(item)
        )

      {:moved, to} ->
        conn |> put_status(301) |> redirect(to: ~p"/items/#{to}")

      :none ->
        conn |> put_status(404) |> put_view(TravelingPoetWeb.ErrorHTML) |> render(:"404")
    end
  end

  def jsonld(conn, %{"slug" => slug}) do
    case Public.lookup(slug) do
      {:ok, item} ->
        body = item |> Public.facts() |> JsonLd.build(base_url()) |> Jason.encode!()

        conn
        |> put_resp_content_type("application/ld+json")
        |> put_resp_header("cache-control", "public, max-age=300")
        |> send_resp(200, body)

      {:moved, to} ->
        conn |> put_status(301) |> redirect(to: ~p"/items/#{to}/jsonld")

      :none ->
        conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def geojson(conn, params) do
    body = params |> Map.take(["kind", "topic", "country"]) |> Public.geojson() |> Jason.encode!()

    conn
    |> put_resp_content_type("application/geo+json")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> send_resp(200, body)
  end

  defp base_url, do: TravelingPoetWeb.Endpoint.url()

  # "a restaurant in Kyoto", "an event", "a dish"
  defp kind_word(%{kind: "place", subkind: subkind}) when is_binary(subkind),
    do: String.replace(subkind, "_", " ")

  defp kind_word(%{kind: kind}), do: kind
end
