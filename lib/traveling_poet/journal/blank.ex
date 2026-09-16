defmodule TravelingPoet.Journal.Blank do
  @moduledoc """
  Placeholder text a model writes where it means "no value".

  Tobias's model, 2026-09-16, sent the string "null" as the title of two
  sections; it was stored and printed on the page as a heading reading
  "null". Short optional fields (titles, teasers, blurbs) go through `clean/1`
  on write, and the notebook checks `present?/1` before printing a title, so
  rows written before this still render cleanly.
  """

  @placeholders ~w(null nil none undefined n/a)

  @doc "The text, trimmed, or nil when it is empty or only a placeholder."
  def clean(nil), do: nil

  def clean(text) when is_binary(text) do
    trimmed = String.trim(text)
    if trimmed == "" or String.downcase(trimmed) in @placeholders, do: nil, else: trimmed
  end

  def clean(other), do: other

  def present?(text), do: not is_nil(clean(text))
end
