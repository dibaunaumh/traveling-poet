defmodule TravelingPoet.IllustrationsTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Illustrations

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  test "a spot draws on the spot model, everything else on the main one" do
    assert Illustrations.model_for("spot") == "test/spot-image-model"
    assert Illustrations.model_for("illustration") == Illustrations.model()
    assert Illustrations.model_for("place") == Illustrations.model()
    assert Illustrations.model_for(nil) == Illustrations.model()
  end

  test "text-and-image models take chat completions; image-only models take the Image API" do
    assert Illustrations.endpoint_for("google/gemini-2.5-flash-image") == :chat
    assert Illustrations.endpoint_for("openai/gpt-5-image-mini") == :chat
    assert Illustrations.endpoint_for("microsoft/mai-image-2.6-flash") == :images
    assert Illustrations.endpoint_for("black-forest-labs/flux.2-klein-4b") == :images
  end

  test "without a key nothing is sent" do
    assert Illustrations.generate("a door") == {:error, :not_configured}
    assert Illustrations.request("a door") == {:error, :not_configured}
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

  test "a spot goes to the Image API, as prompt and model, and comes back decoded" do
    Req.Test.stub(TravelingPoet.Illustrations, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert conn.request_path == "/api/v1/images"

      assert Jason.decode!(body) == %{
               "model" => "test/spot-image-model",
               "prompt" => "an iron door knocker"
             }

      Req.Test.json(conn, %{
        "data" => [%{"b64_json" => Base.encode64(@png), "media_type" => "image/jpeg"}],
        "usage" => %{"cost" => 0.0197}
      })
    end)

    assert {:ok, %{bytes: @png, content_type: "image/jpeg", cost: 0.0197}} =
             Illustrations.request("an iron door knocker",
               api_key: "k",
               model: Illustrations.model_for("spot")
             )
  end

  test "an unknown media type is served as png; an error status is an error" do
    Req.Test.stub(TravelingPoet.Illustrations, fn conn ->
      Req.Test.json(conn, %{
        "data" => [%{"b64_json" => Base.encode64(@png), "media_type" => "image/svg+xml"}]
      })
    end)

    assert {:ok, %{content_type: "image/png", cost: nil}} =
             Illustrations.request("x", api_key: "k", model: "m/image-only")

    Req.Test.stub(TravelingPoet.Illustrations, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => %{"code" => 404}})
    end)

    assert {:error, "image API returned 404"} =
             Illustrations.request("x", api_key: "k", model: "m/image-only")
  end
end
