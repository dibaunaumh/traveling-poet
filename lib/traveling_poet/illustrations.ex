defmodule TravelingPoet.Illustrations do
  @moduledoc """
  Server-side illustration generation via OpenRouter: chat completions with
  image output (base64 data URLs in `message.images`) for the fleet today, and
  the Image API for image-only models (see `request/2`).

  Generation deliberately happens HERE and not on the sprite: the sprite is
  user-driven territory, so shared secrets never go there. The agent calls
  the `generate_illustration` tool -> POST /api/agent/illustrations -> this
  module -> OpenRouter, with the image quota enforced app-side. Using
  OpenRouter (same key as the text models) keeps billing and rotation in one
  place — IMAGE_GEN_API_KEY no longer exists.
  """

  require Logger

  @api_url "https://openrouter.ai/api/v1/chat/completions"

  # The model reads "travel-journal sketch" literally and paints a sketchbook
  # around the scene: spiral binding, page edges, a hand. The drawing is
  # taped into a notebook already; the scene has to fill the image. Added
  # app-side so it holds whatever the poet's own prompt says.
  @framing " The image is the scene itself, filling the frame edge to edge:" <>
             " no sketchbook, notebook, spiral binding, page edges, paper border, frame, tape, or hands."

  # A spot drawing sits inside the prose, blended onto the paper with CSS
  # multiply, which makes pure white vanish and lets a wash sit on the paper
  # like real watercolour. Colour is welcome where it carries the meaning (a
  # textile, a fruit, a sky); the background is the thing that must stay
  # clean, and the model cannot be trusted with that from the poet's prompt
  # alone, so the app says it every time.
  @ink " A small drawing of one detail: black ink line, with a light watercolour wash" <>
         " where colour carries the meaning, otherwise plain ink." <>
         " The background must be pure white (#FFFFFF), the white of the page itself:" <>
         " no paper texture, no grey, no vignette, no shadow, no border, no frame, no text." <>
         " The subject sits alone on blank white."

  @images_url "https://openrouter.ai/api/v1/images"

  def configured? do
    Application.get_env(:traveling_poet, :openrouter_api_key) not in [nil, ""]
  end

  def model do
    Application.get_env(:traveling_poet, :image_gen_model, "google/gemini-2.5-flash-image")
  end

  @doc "The style rules the app appends to every poet prompt, by media kind."
  def style_suffix("spot"), do: @ink <> @framing
  def style_suffix(_kind), do: @framing

  @doc """
  Generates an image for the prompt.
  Returns {:ok, bytes, content_type} | {:error, reason}.
  """
  def generate(prompt) when is_binary(prompt) do
    case request(prompt) do
      {:ok, %{bytes: bytes, content_type: content_type}} -> {:ok, bytes, content_type}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  One generation call, with what it cost.

  Returns `{:ok, %{bytes, content_type, cost, ms}}` or `{:error, reason}`.
  `cost` is OpenRouter's reported USD for the call (nil when it reports none).

  Options:
    * `:model` (default `model/0`)
    * `:api_key` (default the fleet key)
    * `:endpoint` - `:chat` (default; chat completions with image output, the
      only route Gemini had when this was written) or `:images` (OpenRouter's
      Image API, the only route for image-only models such as FLUX or Qwen)
    * `:params` - extra Image API fields (`resolution`, `aspect_ratio`)
  """
  def request(prompt, opts \\ []) when is_binary(prompt) do
    key = Keyword.get(opts, :api_key, Application.get_env(:traveling_poet, :openrouter_api_key))
    model = Keyword.get(opts, :model, model())

    if key in [nil, ""] do
      {:error, :not_configured}
    else
      {url, body} = request_body(Keyword.get(opts, :endpoint, :chat), model, prompt, opts)
      t0 = System.monotonic_time(:millisecond)

      req_opts =
        [
          json: body,
          headers: [{"authorization", "Bearer #{key}"}],
          receive_timeout: 120_000
        ] ++ Application.get_env(:traveling_poet, :illustrations_req_options, [])

      case Req.post(url, req_opts) do
        {:ok, %{status: 200, body: resp}} ->
          with {:ok, bytes, content_type} <- extract_image(resp) do
            {:ok,
             %{
               bytes: bytes,
               content_type: content_type,
               cost: get_in(resp, ["usage", "cost"]),
               ms: System.monotonic_time(:millisecond) - t0
             }}
          end

        {:ok, %{status: status, body: resp}} ->
          Logger.warning(
            "Illustrations: OpenRouter returned #{status}: #{inspect(resp, limit: 300)}"
          )

          {:error, "image API returned #{status}"}

        {:error, reason} ->
          Logger.warning("Illustrations: request failed: #{inspect(reason)}")
          {:error, "image API request failed"}
      end
    end
  end

  defp request_body(:chat, model, prompt, _opts) do
    {@api_url,
     %{
       model: model,
       messages: [%{role: "user", content: prompt}],
       modalities: ["image", "text"],
       usage: %{include: true}
     }}
  end

  defp request_body(:images, model, prompt, opts) do
    {@images_url,
     Map.merge(Map.new(Keyword.get(opts, :params, %{})), %{model: model, prompt: prompt})}
  end

  # Image API: `data: [%{b64_json, media_type}]`
  defp extract_image(%{"data" => [%{"b64_json" => b64} = img | _]}) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bytes} -> {:ok, bytes, normalize_type(img["media_type"])}
      :error -> {:error, "no image in response"}
    end
  end

  defp extract_image(%{"choices" => choices}) when is_list(choices) do
    choices
    |> Enum.flat_map(fn c -> get_in(c, ["message", "images"]) || [] end)
    |> Enum.find_value(fn img ->
      case get_in(img, ["image_url", "url"]) do
        "data:" <> _ = data_url -> decode_data_url(data_url)
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, "no image in response"}
      {bytes, content_type} -> {:ok, bytes, content_type}
    end
  end

  defp extract_image(_), do: {:error, "no image in response"}

  defp decode_data_url("data:" <> rest) do
    with [meta, b64] <- String.split(rest, ",", parts: 2),
         {:ok, bytes} <- Base.decode64(b64) do
      {bytes, normalize_type(meta |> String.split(";") |> hd())}
    else
      _ -> nil
    end
  end

  # normalize to the types the media pipeline serves; default png
  defp normalize_type(ct) when ct in ["image/png", "image/jpeg", "image/webp"], do: ct
  defp normalize_type(_), do: "image/png"
end
