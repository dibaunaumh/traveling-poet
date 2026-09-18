defmodule TravelingPoet.DeadLinksTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.DeadLinks

  # dead.example answers 404; everything else is alive
  setup do
    Req.Test.stub(TravelingPoet.LinkCheck, fn conn ->
      if conn.host == "dead.example",
        do: Plug.Conn.send_resp(conn, 404, "gone"),
        else: Req.Test.text(conn, "ok")
    end)

    :ok
  end

  test "finds inline links and autolinks, never images" do
    body = """
    The [market](https://live.example/m "Market") opens at six. See <https://dead.example/x>.
    ![drawing](/media/12) and ![photo](https://live.example/p.jpg)
    """

    assert DeadLinks.body_links(body) == ["https://live.example/m", "https://dead.example/x"]
    assert DeadLinks.body_links(nil) == []
  end

  test "a dead link keeps its words, a live one is untouched" do
    body =
      "The [old mill](https://dead.example/mill) and [the bridge](https://live.example/b); <https://dead.example/a>."

    dead = MapSet.new(["https://dead.example/mill", "https://dead.example/a"])

    assert DeadLinks.unlink(body, dead) ==
             "The old mill and [the bridge](https://live.example/b); https://dead.example/a."
  end

  test "sections: only dead links are unlinked, and they are reported" do
    sections = [
      %{"kind" => "description", "body" => "At [the dock](https://dead.example/dock) at dawn."},
      %{"kind" => "poem", "body" => "No links here."},
      %{"kind" => "art_culture", "body" => "The [gallery](https://live.example/g)."}
    ]

    {out, unlinked} = DeadLinks.unlink_sections(sections)

    assert Enum.map(out, & &1["body"]) == [
             "At the dock at dawn.",
             "No links here.",
             "The [gallery](https://live.example/g)."
           ]

    assert unlinked == ["https://dead.example/dock"]
  end

  test "entry sources: dead items are dropped in either shape" do
    assert {%{"items" => [%{"url" => "https://live.example/a"}]}, ["https://dead.example/b"]} =
             DeadLinks.prune_sources(%{
               "items" => [
                 %{"url" => "https://live.example/a"},
                 %{"url" => "https://dead.example/b"}
               ]
             })

    assert {["https://live.example/a"], ["https://dead.example/b"]} =
             DeadLinks.prune_sources(["https://live.example/a", "https://dead.example/b"])

    assert {%{}, []} = DeadLinks.prune_sources(%{})
  end
end
