defmodule TravelingPoet.Illustrations do
  @moduledoc """
  Server-side illustration generation via the Gemini image API.

  Generation deliberately happens HERE and not on the sprite: the sprite is
  user-driven territory (a user talked their agent into reading the sprite
  .env and exfiltrated the shared keys), so shared secrets never go there.
  The agent calls the `generate_illustration` tool -> POST
  /api/agent/illustrations -> this module -> Gemini, with the image quota
  enforced app-side.
  """

  require Logger

  @base_url "https://generativelanguage.googleapis.com/v1beta/models"

  def configured? do
    Application.get_env(:traveling_poet, :image_gen_api_key) not in [nil, ""]
  end

  @doc "Generates a PNG for the prompt. Returns {:ok, png_bytes} | {:error, reason}."
  def generate(prompt) when is_binary(prompt) do
    key = Application.get_env(:traveling_poet, :image_gen_api_key)
    model = Application.get_env(:traveling_poet, :image_gen_model, "gemini-2.5-flash-image")

    if key in [nil, ""] do
      {:error, :not_configured}
    else
      body = %{
        contents: [%{parts: [%{text: prompt}]}],
        generationConfig: %{responseModalities: ["IMAGE"]}
      }

      case Req.post("#{@base_url}/#{model}:generateContent",
             json: body,
             headers: [{"x-goog-api-key", key}],
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200, body: resp}} ->
          extract_image(resp)

        {:ok, %{status: status, body: resp}} ->
          Logger.warning("Illustrations: Gemini returned #{status}: #{inspect(resp, limit: 300)}")
          {:error, "image API returned #{status}"}

        {:error, reason} ->
          Logger.warning("Illustrations: request failed: #{inspect(reason)}")
          {:error, "image API request failed"}
      end
    end
  end

  defp extract_image(%{"candidates" => candidates}) when is_list(candidates) do
    candidates
    |> Enum.flat_map(fn c -> get_in(c, ["content", "parts"]) || [] end)
    |> Enum.find_value(fn part ->
      data = get_in(part, ["inlineData", "data"]) || get_in(part, ["inline_data", "data"])
      data && Base.decode64(data) |> elem_ok()
    end)
    |> case do
      nil -> {:error, "no image in response"}
      bytes -> {:ok, bytes}
    end
  end

  defp extract_image(_), do: {:error, "no image in response"}

  defp elem_ok({:ok, bytes}), do: bytes
  defp elem_ok(_), do: nil
end
