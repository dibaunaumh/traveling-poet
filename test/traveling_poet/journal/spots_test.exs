defmodule TravelingPoet.Journal.SpotsTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Journal.Spots

  defp section(kind, body), do: %{kind: kind, body: body, position: 0}
  defp spot(id), do: %TravelingPoet.Journal.Media{id: id, kind: "spot", alt_text: "cup #{id}"}

  @body "One.\n\nTwo.\n\nThree.\n\nFour.\n\nFive."

  test "an unpasted drawing is woven before the second paragraph, the next before the fourth" do
    [d] = Spots.embed_unclaimed([section("description", @body)], [spot(1), spot(2)])

    assert d.body ==
             "One.\n\n![cup 1](/media/1)\n\nTwo.\n\nThree.\n\n![cup 2](/media/2)\n\nFour.\n\nFive."
  end

  test "text too short to host them takes the rest at the end" do
    [d] =
      Spots.embed_unclaimed([section("description", "Only one paragraph.")], [spot(1), spot(2)])

    assert d.body == "Only one paragraph.\n\n![cup 1](/media/1)\n\n![cup 2](/media/2)"
  end

  test "a drawing already pasted anywhere is left alone; the description hosts the rest" do
    sections = [
      section("poem", "verse"),
      section("description", @body),
      section("products", "A rope.\n\n![knot](/media/1)\n\nMore.")
    ]

    [poem, d, products] = Spots.embed_unclaimed(sections, [spot(1), spot(2)])

    assert poem.body == "verse"
    assert products.body =~ "/media/1"
    refute d.body =~ "/media/1"
    assert d.body =~ "One.\n\n![cup 2](/media/2)\n\nTwo."
  end

  test "with no description the first prose section hosts them; with no prose, nothing changes" do
    [poem, notes] =
      Spots.embed_unclaimed([section("poem", "verse"), section("art_culture", "A.\n\nB.")], [
        spot(3)
      ])

    assert poem.body == "verse"
    assert notes.body == "A.\n\n![cup 3](/media/3)\n\nB."

    assert Spots.embed_unclaimed([section("poem", "verse")], [spot(3)]) == [
             section("poem", "verse")
           ]

    assert Spots.embed_unclaimed([section("description", @body)], []) == [
             section("description", @body)
           ]
  end
end
