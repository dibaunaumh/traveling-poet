defmodule TravelingPoet.MapsLinks do
  @moduledoc """
  Takes a reader's places to Google Maps (card-94): a search link per place,
  and a KML file of their saved places that Google My Maps imports as a map
  they can carry on the trip. Pure: no Repo, no HTTP.
  """

  @doc """
  A Google Maps link for a place: by name and address when there is an
  address (Maps then lands on the business, not a bare pin), else by its
  coordinates, else nil.
  """
  def google_url(%{name: name} = place) do
    query =
      cond do
        present?(Map.get(place, :address)) ->
          "#{name}, #{Map.get(place, :address)}"

        is_number(Map.get(place, :lat)) and is_number(Map.get(place, :lng)) ->
          "#{place.lat},#{place.lng}"

        true ->
          nil
      end

    if query, do: "https://www.google.com/maps/search/?api=1&query=" <> URI.encode_www_form(query)
  end

  def google_url(_), do: nil

  @doc "A KML document of the places that have coordinates."
  def kml(places, title) do
    marks =
      places
      |> Enum.filter(&(is_number(Map.get(&1, :lat)) and is_number(Map.get(&1, :lng))))
      |> Enum.map(&placemark/1)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
    <Document>
    <name>#{esc(title)}</name>
    #{Enum.join(marks, "\n")}
    </Document>
    </kml>
    """
  end

  defp placemark(place) do
    description =
      [Map.get(place, :blurb), Map.get(place, :address), Map.get(place, :source_url)]
      |> Enum.filter(&present?/1)
      |> Enum.join("\n")

    """
    <Placemark>
    <name>#{esc(place.name)}</name>
    <description>#{esc(description)}</description>
    <Point><coordinates>#{place.lng},#{place.lat}</coordinates></Point>
    </Placemark>
    """
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""

  defp esc(nil), do: ""

  defp esc(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
