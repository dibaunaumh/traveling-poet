defmodule TravelingPoet.Guide.Extractor do
  @moduledoc """
  Pulls the places out of an already-published journal entry.

  This is the app's ONLY server-side text LLM call. Everything else the poet
  writes is written on its own sprite; this exists purely so trips that
  predate the trip guide are not left empty, and it is driven by
  `mix tpoet.backfill_places` rather than by anything in the request path.

  Extraction, never invention. The prompt says so and the parser enforces what
  it can: a source_url that does not appear verbatim in the entry is dropped,
  and `poet_rating` is deliberately never extracted. Inferring "how warmly did
  this entry speak about the place" and presenting the result as the poet's own
  1-5 rating would be fabricating the one field the whole feature promises is
  the poet's own voice.
  """

  require Logger

  @api_url "https://openrouter.ai/api/v1/chat/completions"
  @max_chars 8_000
  # Prose only -- a poem is the last place to go looking for a street address.
  #
  # `kindness` is deliberately EXCLUDED. That section carries a charity or a
  # food bank, and the extractor has no category that fits, so it labelled them
  # "attraction": the 2026-09-01 dry run turned "Banco Alimentar Contra a Fome"
  # and "Santa Casa da Misericordia de Sintra" into tourist attractions. A
  # kindness opportunity already has its own prominent place in the entry with
  # an official link; recasting it as somewhere to go sightseeing misrepresents
  # both the place and the poet.
  @prose_kinds ~w(description art_culture products)

  def configured?,
    do: Application.get_env(:traveling_poet, :openrouter_api_key) not in [nil, ""]

  def model,
    do: Application.get_env(:traveling_poet, :extraction_model, "google/gemini-2.5-flash")

  @doc """
  Returns `{:ok, [place_attrs]}` or `{:error, reason}`.

  An entry that recommends nothing specific yields `{:ok, []}` — a normal
  outcome, not a failure.
  """
  def extract(entry, sections) do
    key = Application.get_env(:traveling_poet, :openrouter_api_key)
    text = prose(sections)

    cond do
      # Checked first: an entry with no prose needs no key and no call to
      # decide it has nothing in it.
      String.trim(text) == "" -> {:ok, []}
      key in [nil, ""] -> {:error, :not_configured}
      true -> request(key, entry, text)
    end
  end

  defp request(key, entry, text) do
    body = %{
      model: model(),
      messages: [
        %{role: "system", content: system_prompt()},
        %{role: "user", content: user_prompt(entry, text)}
      ],
      response_format: %{type: "json_object"}
    }

    case Req.post(@api_url,
           json: body,
           headers: [{"authorization", "Bearer #{key}"}],
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: resp}} ->
        resp |> content() |> parse_response() |> sanitize(text)

      {:ok, %{status: status, body: resp}} ->
        Logger.warning("Extractor: OpenRouter returned #{status}: #{inspect(resp, limit: 300)}")
        {:error, "extraction API returned #{status}"}

      {:error, reason} ->
        Logger.warning("Extractor: request failed: #{inspect(reason)}")
        {:error, "extraction API request failed"}
    end
  end

  defp content(%{"choices" => [%{"message" => %{"content" => c}} | _]}) when is_binary(c), do: c
  defp content(_), do: ""

  @doc """
  Parses whatever the model returned into a list of maps.

  Public because this, not the HTTP call, is where the real risk lives: the
  repo's standing lesson is that the fleet models fumble structured output
  often enough that a malformed response must never break a run. Accepts a
  bare array, a {"places": [...]} object, and either wrapped in markdown
  fences; anything else yields [].
  """
  def parse_response(raw) when is_binary(raw) do
    raw
    |> strip_fences()
    |> Jason.decode()
    |> case do
      {:ok, %{"places" => places}} when is_list(places) -> places
      {:ok, places} when is_list(places) -> places
      _ -> []
    end
    |> Enum.filter(&is_map/1)
  end

  def parse_response(_), do: []

  defp strip_fences(raw) do
    raw
    |> String.trim()
    |> String.replace(~r/\A```(?:json)?\s*/i, "")
    |> String.replace(~r/```\s*\z/, "")
    |> String.trim()
  end

  # Everything the model returns is treated as a claim about the entry, not a
  # fact about the world.
  defp sanitize(places, source_text) do
    cleaned =
      places
      |> Enum.map(&clean_place(&1, source_text))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1["name"])

    {:ok, cleaned}
  end

  defp clean_place(place, source_text) do
    name = place |> Map.get("name") |> to_string() |> String.trim()

    if name == "" do
      nil
    else
      %{
        "name" => name,
        "category" => TravelingPoet.Guide.Place.normalize_category(place["category"]),
        "address" => trimmed(place["address"]),
        "blurb" => trimmed(place["blurb"]),
        # Only a URL the entry actually contains. A model asked for a link
        # will happily produce a plausible one.
        "source_url" => verbatim_url(place["source_url"], source_text),
        "source" => "backfill"
      }
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_), do: nil

  defp verbatim_url(url, source_text) when is_binary(url) do
    if String.contains?(source_text, String.trim(url)), do: String.trim(url), else: nil
  end

  defp verbatim_url(_, _), do: nil

  defp prose(sections) do
    sections
    |> Enum.filter(&(&1.kind in @prose_kinds))
    |> Enum.map_join("\n\n", &to_string(&1.body))
    |> String.slice(0, @max_chars)
  end

  defp system_prompt do
    """
    You extract a trip guide from a travel journal entry.

    Return a JSON object: {"places": [...]}. List ONLY specific, named places
    the entry actually mentions or recommends. Fields per place:

      name        the place's own name, as the entry gives it
      category    one of: restaurant, cafe, viewpoint, attraction, event,
                  landmark, shop
      address     ONLY if the entry states one; otherwise omit
      blurb       one sentence, quoted or closely paraphrased FROM THE ENTRY
      source_url  ONLY a URL that appears literally in the entry; otherwise omit

    Rules:
    - Do NOT invent places, addresses, or URLs. Do not add well-known places
      the entry does not mention.
    - "the old town", "a small cafe", "the river" are not places. Skip them.
    - Do NOT rate the places. There is no rating field.
    - If the entry names nothing specific, return {"places": []}.
    """
  end

  defp user_prompt(entry, text) do
    """
    Entry date: #{entry.entry_date}
    Place: #{entry.place_name}
    Title: #{entry.title}

    ---
    #{text}
    """
  end
end
