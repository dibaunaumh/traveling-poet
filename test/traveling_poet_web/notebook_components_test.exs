defmodule TravelingPoetWeb.NotebookComponentsTest do
  use ExUnit.Case, async: true

  import TravelingPoetWeb.NotebookComponents,
    only: [raw_markdown: 1, raw_markdown: 2, raw_markdown: 3, place_links: 2]

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

  test "an own drawing given with its media becomes a link to what it was drawn from" do
    media = %TravelingPoet.Journal.Media{
      id: 42,
      sources: %{
        "items" => [
          %{"url" => "https://example.com/rope", "label" => "the patio"},
          %{"url" => "https://example.com/2", "label" => "another"}
        ]
      }
    }

    out = html(raw_markdown("Before\n\n![a rope](/media/42)\n\nAfter.", %{42 => media}))

    assert out =~
             ~s(<a href="https://example.com/rope" title="Drawn from the patio, another" rel="noopener noreferrer"><img src="/media/42" alt="a rope"></a>)

    assert text(raw_markdown("x ![a rope](/media/42) y", %{42 => media})) ==
             text(raw_markdown("x  y"))

    # no sources on record (should not happen; the changeset requires them): plain image, still own
    bare =
      html(
        raw_markdown("![a rope](/media/42)", %{
          42 => %TravelingPoet.Journal.Media{id: 42, sources: %{}}
        })
      )

    assert bare =~ ~s(<img src="/media/42")
    refute bare =~ "<a "
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

  describe "place links in the prose" do
    @links [
      %{name: "Cafe Museum", href: "/journal/2026-09-11?spread=places#stop-1"},
      %{name: "Cafe", href: "/journal/2026-09-11?spread=places#stop-2"},
      %{name: "Puente Nuevo", href: "/journal/2026-09-11?spread=places#stop-3"}
    ]

    test "the first mention of each place becomes a link; later mentions stay plain" do
      md =
        "Morning at Cafe Museum, then Puente Nuevo. Back to Cafe Museum at dusk, over Puente Nuevo."

      out = html(raw_markdown(md, [], @links))

      assert out =~
               ~s(<a href="/journal/2026-09-11?spread=places#stop-1" rel="noopener noreferrer">Cafe Museum</a>)

      assert out =~ ~s(#stop-3" rel="noopener noreferrer">Puente Nuevo</a>)
      assert length(Regex.scan(~r/<a /, out)) == 2
    end

    test "the longer name wins where names nest, and the short one still gets its own first mention" do
      out = html(raw_markdown("Cafe Museum first, the Cafe second.", [], @links))

      assert out =~ ~s(#stop-1" rel="noopener noreferrer">Cafe Museum</a>)
      assert out =~ ~s(#stop-2" rel="noopener noreferrer">Cafe</a>)
      assert length(Regex.scan(~r/<a /, out)) == 2
    end

    test "matches whole words only, case-insensitively, across paragraphs and emphasis" do
      md = "The cafes were shut.\n\nWe found *cafe museum* open, and a **Puente** nearby."
      out = html(raw_markdown(md, [], @links))

      assert out =~
               ~s(<em><a href="/journal/2026-09-11?spread=places#stop-1" rel="noopener noreferrer">cafe museum</a></em>)

      refute out =~ ~s(>cafes</a>)
      refute out =~ ~s(Puente</a>)
    end

    test "text the poet already linked, and code, are left alone" do
      md = "See [Cafe Museum](https://example.com/cm) and `Puente Nuevo` and then Puente Nuevo."
      out = html(raw_markdown(md, [], @links))

      assert out =~ ~s(<a href="https://example.com/cm" rel="noopener noreferrer">Cafe Museum</a>)
      assert out =~ "<code>Puente Nuevo</code>"
      assert out =~ ~s(#stop-3" rel="noopener noreferrer">Puente Nuevo</a>)
      assert length(Regex.scan(~r/<a /, out)) == 2
    end

    test "linking never changes the visible text, so marker offsets hold" do
      md = "Morning at Cafe Museum (C&M), then *Puente Nuevo*; back to Cafe Museum."
      assert text(raw_markdown(md, [], @links)) == text(raw_markdown(md))
    end

    test "regex specials in a name are literal, and short names are not linked at all" do
      links =
        place_links([%{id: 9, name: "Bar (Sur)"}, %{id: 10, name: "Sur"}], "/p/nam/2026-09-11")

      assert links == [%{name: "Bar (Sur)", href: "/p/nam/2026-09-11?spread=places#stop-9"}]

      out = html(raw_markdown("Drinks at Bar (Sur), by the Sur.", [], links))
      assert out =~ ~s|#stop-9" rel="noopener noreferrer">Bar (Sur)</a>|
      assert length(Regex.scan(~r/<a /, out)) == 1
    end
  end
end
