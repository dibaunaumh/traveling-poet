defmodule TravelingPoetWeb.ItemHTML do
  @moduledoc "The public page of a Spaces item. See `ItemController`."
  use TravelingPoetWeb, :html

  embed_templates "item_html/*"

  def date_range(%{time_start: nil, time_end: nil}), do: nil
  def date_range(%{time_start: s, time_end: nil}), do: "from " <> fmt(s)
  def date_range(%{time_start: nil, time_end: e}), do: "until " <> fmt(e)
  def date_range(%{time_start: s, time_end: s}), do: fmt(s)
  def date_range(%{time_start: s, time_end: e}), do: fmt(s) <> " to " <> fmt(e)

  def fmt(%Date{} = date), do: Calendar.strftime(date, "%b %-d, %Y")

  def phrase("at", :out), do: "at"
  def phrase("at", :in), do: "here:"
  def phrase("part_of", :out), do: "part of"
  def phrase("part_of", :in), do: "includes"
  def phrase("made_by", :out), do: "made by"
  def phrase("made_by", :in), do: "made"
  def phrase("commemorates", :out), do: "commemorates"
  def phrase("commemorates", :in), do: "remembered by"
  def phrase("about", :out), do: "about"
  def phrase("about", :in), do: "the subject of"
  def phrase("series_of", :out), do: "a later edition of"
  def phrase("series_of", :in), do: "returned as"
  def phrase(relation, _), do: String.replace(relation, "_", " ")
end
