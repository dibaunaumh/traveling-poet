defmodule TravelingPoetWeb.ItemHTML do
  @moduledoc "The public page of a Spaces item. See `ItemController`."
  use TravelingPoetWeb, :html

  embed_templates "item_html/*"

  def date_range(%{time_start: nil, time_end: nil}), do: nil

  def date_range(%{time_start: s, time_end: nil}),
    do: dgettext("guide", "from %{date}", date: fmt(s))

  def date_range(%{time_start: nil, time_end: e}),
    do: dgettext("guide", "until %{date}", date: fmt(e))

  def date_range(%{time_start: s, time_end: s}), do: fmt(s)

  def date_range(%{time_start: s, time_end: e}),
    do: dgettext("guide", "%{from} to %{to}", from: fmt(s), to: fmt(e))

  def fmt(%Date{} = date), do: TravelingPoet.Locale.format_date(date, :short_year)

  def phrase("at", :out), do: dgettext("guide", "at")
  def phrase("at", :in), do: dgettext("guide", "here:")
  def phrase("part_of", :out), do: dgettext("guide", "part of")
  def phrase("part_of", :in), do: dgettext("guide", "includes")
  def phrase("made_by", :out), do: dgettext("guide", "made by")
  def phrase("made_by", :in), do: dgettext("guide", "made")
  def phrase("commemorates", :out), do: dgettext("guide", "commemorates")
  def phrase("commemorates", :in), do: dgettext("guide", "remembered by")
  def phrase("about", :out), do: dgettext("guide", "about")
  def phrase("about", :in), do: dgettext("guide", "the subject of")
  def phrase("series_of", :out), do: dgettext("guide", "a later edition of")
  def phrase("series_of", :in), do: dgettext("guide", "returned as")
  def phrase(relation, _), do: String.replace(relation, "_", " ")

  @doc """
  The item's kind as the page's first line says it ("restaurant", "event").
  Item kinds and place categories are closed lists, so each has its
  translation; a place type from the subject tree is data, shown as it is.
  """
  def kind_label("place"), do: dgettext("guide", "place")
  def kind_label("event"), do: dgettext("guide", "event")
  def kind_label("artwork"), do: dgettext("guide", "artwork")
  def kind_label("dish"), do: dgettext("guide", "dish")
  def kind_label("encounter"), do: dgettext("guide", "encounter")
  def kind_label("person"), do: dgettext("guide", "person")
  def kind_label("product"), do: dgettext("guide", "product")
  def kind_label("idea"), do: dgettext("guide", "idea")
  def kind_label("work"), do: dgettext("guide", "work")
  def kind_label("other"), do: dgettext("guide", "other")
  def kind_label("restaurant"), do: dgettext("guide", "restaurant")
  def kind_label("cafe"), do: dgettext("guide", "cafe")
  def kind_label("viewpoint"), do: dgettext("guide", "viewpoint")
  def kind_label("attraction"), do: dgettext("guide", "attraction")
  def kind_label("landmark"), do: dgettext("guide", "landmark")
  def kind_label("shop"), do: dgettext("guide", "shop")
  def kind_label(word), do: word
end
