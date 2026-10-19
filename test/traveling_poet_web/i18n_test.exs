defmodule TravelingPoetWeb.I18nTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import TravelingPoetWeb.I18n

  test "a translated sentence keeps its markup wherever the language puts it" do
    assigns = %{text: "קראו את #{marker(:guide)}. לפני היציאה <b>"}

    html =
      rendered_to_string(~H"""
      <.rich text={@text}>
        <:part name="guide">
          <a href="/guide">המדריך</a>
        </:part>
      </.rich>
      """)

    assert html =~ ~r{קראו את <a[^>]* href="/guide">המדריך</a>\. לפני היציאה &lt;b&gt;}u
  end

  test "pieces" do
    assert pieces("a #{marker(:x)} b") == ["a ", {:part, "x"}, " b"]
    assert pieces(marker(:x)) == [{:part, "x"}]
  end
end
