defmodule TravelingPoet.IllustrationsTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Illustrations

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  test "a spot gets the ink rules and the framing rule; everything else only the framing" do
    assert Illustrations.style_suffix("spot") =~ "pure white (#FFFFFF)"
    assert Illustrations.style_suffix("spot") =~ "edge to edge"
    refute Illustrations.style_suffix("illustration") =~ "#FFFFFF"
    assert Illustrations.style_suffix("illustration") =~ "no sketchbook"
    assert Illustrations.style_suffix(nil) == Illustrations.style_suffix("illustration")
  end

  test "without a key nothing is sent" do
    assert Illustrations.request("a door") == {:error, :not_configured}
    assert Illustrations.generate("a door") == {:error, :not_configured}
  end

  test "chat completions: image out of message.images, cost out of usage" do
    Req.Test.stub(TravelingPoet.Illustrations, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      assert conn.request_path == "/api/v1/chat/completions"
      assert body["modalities"] == ["image", "text"]
      assert body["model"] == "google/gemini-2.5-flash-image"

      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "images" => [
                %{"image_url" => %{"url" => "data:image/png;base64," <> Base.encode64(@png)}}
              ]
            }
          }
        ],
        "usage" => %{"cost" => 0.0388}
      })
    end)

    assert {:ok, %{bytes: @png, content_type: "image/png", cost: 0.0388, ms: ms}} =
             Illustrations.request("a door",
               api_key: "k",
               model: "google/gemini-2.5-flash-image"
             )

    assert is_integer(ms)
  end

  test "Image API: prompt and params in the body, image out of data" do
    Req.Test.stub(TravelingPoet.Illustrations, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      assert conn.request_path == "/api/v1/images"
      assert body == %{"model" => "qwen/qwen-image-3", "prompt" => "a door", "resolution" => "1K"}

      Req.Test.json(conn, %{
        "data" => [%{"b64_json" => Base.encode64(@png), "media_type" => "image/jpeg"}],
        "usage" => %{"cost" => 0.03}
      })
    end)

    assert {:ok, %{bytes: @png, content_type: "image/jpeg", cost: 0.03}} =
             Illustrations.request("a door",
               api_key: "k",
               model: "qwen/qwen-image-3",
               endpoint: :images,
               params: %{resolution: "1K"}
             )
  end

  test "an unknown media type is served as png; an error status is an error" do
    Req.Test.stub(TravelingPoet.Illustrations, fn conn ->
      Req.Test.json(conn, %{
        "data" => [%{"b64_json" => Base.encode64(@png), "media_type" => "image/svg+xml"}]
      })
    end)

    assert {:ok, %{content_type: "image/png", cost: nil}} =
             Illustrations.request("x", api_key: "k", endpoint: :images)

    Req.Test.stub(TravelingPoet.Illustrations, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => %{"code" => 404}})
    end)

    assert {:error, "image API returned 404"} =
             Illustrations.request("x", api_key: "k", endpoint: :images)
  end
end
