defmodule TravelingPoet.Evals.ImageJudge do
  @moduledoc """
  Vision-model pre-screen for the image eval (`TravelingPoet.Evals.Images`).

  It checks what a model can check reliably and a human should not have to:
  does the image show the prompt's subject, and does it break the style rules
  the app appends to every prompt (no sketchbook or frame, no added text, and
  for a spot a clean white background). Taste stays with the human judge; a
  failed screen only folds the image away on the judging page, it never hides
  it.

  Eval-only, like `Guide.Extractor`'s one server-side text call: nothing in
  the request path uses this module.
  """

  @api_url "https://openrouter.ai/api/v1/chat/completions"

  def model do
    Application.get_env(:traveling_poet, :eval_judge_model, "anthropic/claude-sonnet-4.6")
  end

  @doc "Returns `{:ok, %{\"pass\", \"subject\", \"issues\", \"reason\"}}` or `{:error, reason}`."
  def screen(bytes, content_type, prompt, kind, opts \\ []) do
    key = Keyword.get(opts, :api_key, Application.get_env(:traveling_poet, :openrouter_api_key))

    if key in [nil, ""] do
      {:error, :not_configured}
    else
      body = %{
        model: model(),
        messages: [
          %{role: "system", content: system_prompt()},
          %{
            role: "user",
            content: [
              %{type: "text", text: user_prompt(prompt, kind)},
              %{
                type: "image_url",
                image_url: %{url: "data:#{content_type};base64," <> Base.encode64(bytes)}
              }
            ]
          }
        ],
        response_format: %{type: "json_object"}
      }

      req_opts =
        [
          json: body,
          headers: [{"authorization", "Bearer #{key}"}],
          receive_timeout: 90_000,
          retry: :transient
        ] ++
          Application.get_env(:traveling_poet, :eval_req_options, [])

      case Req.post(@api_url, req_opts) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => raw}} | _]}}} ->
          parse_response(raw)

        {:ok, %{status: status}} ->
          {:error, "judge returned #{status}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  def parse_response(raw) when is_binary(raw) do
    # the first {...} in the reply: models sometimes wrap it in a fence or a sentence
    json =
      case Regex.run(~r/\{.*\}/s, raw) do
        [obj] -> obj
        nil -> raw
      end

    case Jason.decode(json) do
      {:ok, %{"pass" => pass} = v} when is_boolean(pass) ->
        {:ok,
         %{
           "pass" => pass,
           "subject" => v["subject"],
           "issues" => List.wrap(v["issues"]) |> Enum.filter(&is_binary/1),
           "reason" => v["reason"] |> to_string() |> String.slice(0, 200)
         }}

      _ ->
        {:error, :unparseable}
    end
  end

  def parse_response(_), do: {:error, :unparseable}

  defp system_prompt do
    """
    You screen illustrations for a travel journal before a human judges them.
    You do not judge taste or beauty. You check rules, and you are strict only
    about clear violations.

    Reply with one JSON object:
    {"pass": true|false,
     "subject": 1-5 (how well the image shows the prompt's main subject and setting),
     "issues": [short strings, only from the list below],
     "reason": "one sentence"}

    Issues (fail if any applies):
    - "wrong subject": the main subject named in the prompt is missing or a different thing
    - "added text": letters, captions, signatures or watermarks that the prompt did not ask for
    - "sketchbook": the image depicts a physical OBJECT around the scene: a notebook, a
      photographed sheet of paper with a shadow or a table under it, spiral binding, tape,
      or hands. Unpainted white paper around the scene is NOT this issue, even when the
      margin is wide or even, and even when the prompt says "edge to edge": loose
      watercolour fading into the white of the page is the house style.
    - "photographic": looks like a photo or 3D render rather than a drawing or painting
    - "collage": several separate panels or vignettes instead of one image
    - "dirty background": (spot drawings only) the background is not plain white: grey, texture, vignette, shadow or a scene
    - "wrong place": a recognisable landmark in the image belongs somewhere else than the prompt says
    - "broken": corrupted, mostly empty, or unreadable

    Pass when there are no issues and subject is 3 or more.
    """
  end

  defp user_prompt(prompt, kind) do
    kind_note =
      if kind == "spot",
        do: "This is a SPOT drawing: one small detail on a pure white background.",
        else: "This is a main illustration: a full scene."

    "#{kind_note}\n\nThe prompt the image model received:\n#{prompt}"
  end
end
