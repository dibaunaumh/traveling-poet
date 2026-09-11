defmodule TravelingPoet.Markers.GuardTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Journal.{Marker, Section}
  alias TravelingPoet.Markers.Guard

  defp section(id, kind, position, body, extra \\ %{}) do
    struct(
      %Section{id: id, kind: kind, position: position, body: body, metadata: %{}},
      extra
    )
  end

  defp marker(kind, attrs \\ %{}) do
    struct(%Marker{kind: kind, target: "text", quote: ""}, attrs)
  end

  defp existing do
    [
      section(1, "description", 0, "Steep streets and a long day."),
      section(2, "poem", 1, "a verse", %{title: "Fog"}),
      section(3, "illustration", 2, nil, %{media_id: 9, metadata: %{"sources" => ["https://a.b"]}}),
      section(4, "products", 3, "Liberty Public Market sells honey.")
    ]
  end

  defp rewritten do
    [
      %{"kind" => "description", "body" => "Rewritten streets.", "position" => 0},
      %{"kind" => "poem", "title" => "Fog", "body" => "a new verse", "position" => 1},
      %{"kind" => "illustration", "media_id" => 9, "metadata" => %{"sources" => ["https://a.b"]}},
      %{"kind" => "products", "body" => "Rewritten honey.", "position" => 3}
    ]
  end

  test "only the section a change-asking marker sits on may change" do
    boring =
      marker("boring", %{section_kind: "description", section_position: 0, quote: "long day"})

    {sections, kept} = Guard.protect(existing(), rewritten(), [boring])

    assert Enum.map(sections, & &1["body"]) ==
             ["Rewritten streets.", "a verse", nil, "Liberty Public Market sells honey."]

    assert kept == ["poem", "products"]
    refute Enum.any?(sections, &Map.has_key?(&1, "position"))
  end

  test "praise markers change nothing" do
    beautiful =
      marker("beautiful", %{section_kind: "poem", section_position: 1, quote: "a verse"})

    {sections, kept} = Guard.protect(existing(), rewritten(), [beautiful])

    assert Enum.map(sections, & &1["body"]) == Enum.map(existing(), & &1.body)
    assert kept == ["description", "poem", "products"]
  end

  test "a marker on the whole entry frees every section" do
    whole = marker("not_creative", %{target: "section", section_kind: nil})

    {sections, kept} = Guard.protect(existing(), rewritten(), [whole])

    assert Enum.map(sections, & &1["body"]) == Enum.map(rewritten(), & &1["body"])
    assert kept == []
  end

  test "a text marker finds its section by quote when the position drifted" do
    link =
      marker("link_needed", %{
        section_kind: "products",
        section_position: 7,
        quote: "Liberty Public Market"
      })

    incoming =
      List.update_at(rewritten(), 3, fn s ->
        Map.merge(s, %{
          "body" => "Liberty Public Market sells honey.",
          "metadata" => %{"source_url" => "https://libertypublicmarketsd.com/"}
        })
      end)

    {sections, kept} = Guard.protect(existing(), incoming, [link])

    assert Enum.at(sections, 3)["metadata"]["source_url"] == "https://libertypublicmarketsd.com/"
    assert kept == ["description", "poem"]
  end

  test "an illustration marker targets the section by media id" do
    redraw = marker("boring", %{target: "illustration", media_id: 9, section_kind: nil})

    incoming =
      rewritten()
      |> List.update_at(2, &Map.put(&1, "media_id", 10))
      |> List.update_at(0, &Map.put(&1, "body", "Steep streets and a long day."))
      |> List.update_at(1, &Map.put(&1, "body", "a verse"))
      |> List.update_at(3, &Map.put(&1, "body", "Liberty Public Market sells honey."))

    {sections, kept} = Guard.protect(existing(), incoming, [redraw])

    assert Enum.at(sections, 2)["media_id"] == 10
    assert kept == []
  end

  test "an added illustration does not shift the pairing, and identical sections are not reported" do
    drawing =
      marker("drawing_needed", %{section_kind: "description", section_position: 0, quote: "Steep"})

    incoming = [
      %{"kind" => "description", "body" => "Steep streets and a long day."},
      %{
        "kind" => "illustration",
        "media_id" => 42,
        "metadata" => %{"sources" => ["https://c.d"]}
      },
      %{"kind" => "poem", "title" => "Fog", "body" => "a verse"},
      %{"kind" => "illustration", "media_id" => 9, "metadata" => %{"sources" => ["https://a.b"]}},
      %{"kind" => "products", "body" => "Liberty Public Market sells honey."}
    ]

    {sections, kept} = Guard.protect(existing(), incoming, [drawing])

    assert Enum.map(sections, &{&1["kind"], &1["media_id"]}) ==
             [
               {"description", nil},
               {"illustration", 42},
               {"poem", nil},
               {"illustration", 9},
               {"products", nil}
             ]

    assert kept == []
  end

  test "a protected section the poet dropped is put back at its old position" do
    boring =
      marker("boring", %{section_kind: "description", section_position: 0, quote: "long day"})

    incoming = rewritten() |> List.delete_at(1)

    {sections, kept} = Guard.protect(existing(), incoming, [boring])

    assert Enum.map(sections, & &1["kind"]) == ["description", "poem", "illustration", "products"]
    assert Enum.at(sections, 1)["body"] == "a verse"
    assert kept == ["products", "poem"]
  end

  test "active markers are pending ones or those sent in the last half hour" do
    now = ~U[2026-09-11 02:11:00Z]

    pending = marker("boring")
    fresh = marker("boring", %{sent_at: DateTime.add(now, -5, :minute)})
    stale = marker("boring", %{sent_at: DateTime.add(now, -45, :minute)})

    assert Guard.active_markers([pending, fresh, stale], now) == [pending, fresh]
  end
end
