defmodule TravelingPoet.LinkCheckTest do
  use ExUnit.Case, async: false

  alias TravelingPoet.LinkCheck

  defp stub(fun), do: Req.Test.stub(TravelingPoet.LinkCheck, fun)

  test "a live page passes" do
    stub(&Plug.Conn.send_resp(&1, 200, "ok"))
    assert LinkCheck.check("https://example.com/page") == :ok
  end

  test "a missing page is dead" do
    stub(&Plug.Conn.send_resp(&1, 404, "no"))
    assert {:error, {:http, 404}} = LinkCheck.check("https://example.com/gone")
  end

  # openai.com answers 403 to any non-browser client, for real and made-up
  # paths alike: a bot wall says nothing about whether the page exists.
  test "a host that refuses non-browser clients counts as unknown and passes" do
    for status <- [401, 403, 429] do
      stub(&Plug.Conn.send_resp(&1, status, "no bots"))
      assert LinkCheck.check("https://openai.com/index/an-alien-mind/") == :ok
    end
  end

  test "a HEAD refusal falls back to GET, which decides" do
    stub(fn conn ->
      case conn.method do
        "HEAD" -> Plug.Conn.send_resp(conn, 405, "")
        "GET" -> Plug.Conn.send_resp(conn, 410, "gone")
      end
    end)

    assert {:error, {:http, 410}} = LinkCheck.check("https://example.com/old")
  end

  test "blocked hosts never reach the network" do
    assert {:error, :invalid_url} = LinkCheck.check("http://localhost:9/nope")
  end
end
