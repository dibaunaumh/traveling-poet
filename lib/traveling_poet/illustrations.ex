defmodule TravelingPoet.Illustrations do
  @moduledoc """
  Server-side illustration generation via OpenRouter's chat-completions API
  (image-output models return base64 data URLs in `message.images`).

  Generation deliberately happens HERE and not on the sprite: the sprite is
  user-driven territory, so shared secrets never go there. The agent calls
  the `generate_illustration` tool -> POST /api/agent/illustrations -> this
  module -> OpenRouter, with the image quota enforced app-side. Using
  OpenRouter (same key as the text models) keeps billing and rotation in one
  place — IMAGE_GEN_API_KEY no longer exists.
  """

  require Logger

  @api_url "https://openrouter.ai/api/v1/chat/completions"

  def configured? do
    Application.get_env(:traveling_poet, :openrouter_api_key) not in [nil, ""]
  end

  def model do
    Application.get_env(:traveling_poet, :image_gen_model, "openai/gpt-5-image-mini")
  end

  @doc """
  Generates an image for the prompt.
  Returns {:ok, bytes, content_type} | {:error, reason}.
  """
  def generate(prompt) when is_binary(prompt) do
    key = Application.get_env(:traveling_poet, :openrouter_api_key)

    if key in [nil, ""] do
      {:error, :not_configured}
    else
      body = %{
        model: model(),
        messages: [%{role: "user", content: prompt}],
        modalities: ["image", "text"]
      }

      case Req.post(@api_url,
             json: body,
             headers: [{"authorization", "Bearer #{key}"}],
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200, body: resp}} ->
          extract_image(resp)

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
      # normalize to the types the media pipeline serves; default png
      content_type =
        case meta |> String.split(";") |> hd() do
          ct when ct in ["image/png", "image/jpeg", "image/webp"] -> ct
          _ -> "image/png"
        end

      {bytes, content_type}
    else
      _ -> nil
    end
  end
end
