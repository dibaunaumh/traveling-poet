defmodule TravelingPoet.Illustrations do
  @moduledoc """
  Server-side illustration generation via OpenRouter: chat completions with
  image output (base64 data URLs in `message.images`) for models that also
  answer in text, and the Image API (`/api/v1/images`) for image-only models,
  which reject chat completions.

  Generation deliberately happens HERE and not on the sprite: the sprite is
  user-driven territory, so shared secrets never go there. The agent calls
  the `generate_illustration` tool -> POST /api/agent/illustrations -> this
  module -> OpenRouter, with the image quota enforced app-side. Using
  OpenRouter (same key as the text models) keeps billing and rotation in one
  place — IMAGE_GEN_API_KEY no longer exists.

  The model depends on what is being drawn (`model_for/1`). The 2026-09-18
  blind eval of 23 real prompts found that spots and main illustrations want
  different models: of 8 spots, 7 of MAI-Image 2.6 Flash's were judged
  publishable against 1 of Gemini's, while on main illustrations the two were
  close and Gemini is far faster than the cheaper alternatives. So spots go
  to SPOT_IMAGE_MODEL and everything else to IMAGE_GEN_MODEL.
  """

  require Logger

  @api_url "https://openrouter.ai/api/v1/chat/completions"
  @images_url "https://openrouter.ai/api/v1/images"

  # Models that answer in text as well as images, and so take chat
  # completions. Everything else on OpenRouter's image list (MAI-Image,
  # FLUX, Seedream, Qwen Image) is image-only and answers 404 there.
  @chat_model_prefixes ["google/gemini-", "openai/gpt-5"]

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

  def configured? do
    Application.get_env(:traveling_poet, :openrouter_api_key) not in [nil, ""]
  end

  @doc "The model for the main drawing, and anything that is not a spot."
  def model do
    Application.get_env(:traveling_poet, :image_gen_model, "google/gemini-2.5-flash-image")
  end

  @doc "The model for spot drawings."
  def spot_model do
    Application.get_env(:traveling_poet, :spot_image_model, "microsoft/mai-image-2.6-flash")
  end

  @doc "The model that draws this media kind."
  def model_for("spot"), do: spot_model()
  def model_for(_kind), do: model()

  @doc "The style rules the app appends to every poet prompt, by media kind."
  def style_suffix("spot"), do: @ink <> @framing
  def style_suffix(_kind), do: @framing

  @doc "Which OpenRouter API a model answers on."
  def endpoint_for(model) when is_binary(model) do
    if String.starts_with?(model, @chat_model_prefixes), do: :chat, else: :images
  end

  @doc """
  Generates an image for the prompt, with the model for `kind`.
  Returns {:ok, bytes, content_type} | {:error, reason}.
  """
  def generate(prompt, kind \\ nil) when is_binary(prompt) do
    case request(prompt, model: model_for(kind)) do
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
    * `:endpoint` - override `endpoint_for/1`, which production never needs
      but the image eval does: it puts every candidate on the Image API so
      they are compared on one route
    * `:params` - extra Image API fields (`resolution`, `aspect_ratio`)
  """
  def request(prompt, opts \\ []) when is_binary(prompt) do
    key = Keyword.get(opts, :api_key, Application.get_env(:traveling_poet, :openrouter_api_key))
    model = Keyword.get(opts, :model, model())

    if key in [nil, ""] do
      {:error, :not_configured}
    else
      endpoint = Keyword.get(opts, :endpoint, endpoint_for(model))
      {url, body} = request_body(endpoint, model, prompt, opts)
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
            "Illustrations: OpenRouter returned #{status} for #{model}: #{inspect(resp, limit: 300)}"
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
