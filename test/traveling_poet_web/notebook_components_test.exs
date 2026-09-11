defmodule TravelingPoetWeb.NotebookComponentsTest do
  use ExUnit.Case, async: true

  import TravelingPoetWeb.NotebookComponents, only: [raw_markdown: 1, raw_markdown: 2]

  defp html(safe), do: safe |> Phoenix.HTML.safe_to_string()
  defp text(safe), do: safe |> html() |> LazyHTML.from_fragment() |> LazyHTML.text()

  test "markdown still renders prose, emphasis and links" do
    out = html(raw_markdown("A *quiet* morning at [Cafe Museum](https://example.com/cafe)."))

    assert out =~ "<em>quiet</em>"
    assert out =~ ~s(<a href="https://example.com/cafe")
    assert out =~ "rel=\"noopener noreferrer\""
  end

  test "an image found online collapses to its alt text" do
    md = "Look: ![the Alhambra at dusk](https://photos.example.com/alhambra.jpg) and more."

    out = raw_markdown(md)

    refute html(out) =~ "<img"
    refute html(out) =~ "photos.example.com"
    assert text(out) == "Look: the Alhambra at dusk and more."
  end

  test "an own drawing is kept only when the caller vouches for its id" do
    md = "Before ![a cup](/media/42) after."

    refute html(raw_markdown(md)) =~ "<img"
    assert html(raw_markdown(md, [41])) =~ "a cup"
    refute html(raw_markdown(md, [41])) =~ "<img"

    kept = html(raw_markdown(md, [42]))
    assert kept =~ ~s(<img src="/media/42" alt="a cup")
  end

  test "a media path with anything after the id is not vouched for" do
    refute html(raw_markdown("![x](/media/42/../../secret)", [42])) =~ "<img"
    refute html(raw_markdown("![x](/media/42?x=1)", [42])) =~ "<img"
  end

  test "raw html and scripts never reach the page" do
    out = html(raw_markdown("hello <script>alert(1)</script> <b onclick=\"x()\">bold</b>"))

    refute out =~ "<script"
    refute out =~ "onclick"
  end

  test "stripping an image leaves the visible text unchanged for marker offsets" do
    plain = "One sentence. Another with a stop."
    with_image = "One sentence. ![](https://x.example/a.png)Another with a stop."

    assert text(raw_markdown(plain)) == text(raw_markdown(with_image))
  end

  test "nil and unparsable input do not crash" do
    assert raw_markdown(nil) == ""
    assert is_binary(html(raw_markdown("just text")))
  end
end
