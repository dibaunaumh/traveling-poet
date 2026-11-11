defmodule TravelingPoet.Evals.Writing.Judge do
  @moduledoc """
  Reads one eval page for its language, blind to the model that wrote it.

  The question is the one Udi raised about Hebrew poets: does the page read
  as natural, grammatical prose in its language, or are there sentences that
  are not really that language at all? The judge counts those and quotes
  them, so the report can say "3 broken sentences" and the page can show
  which. It does not rank style; Udi does that on the blind page.

  Eval-only, like `Evals.ImageJudge`. `EVAL_JUDGE_MODEL` picks the model.
  """

  alias TravelingPoet.Evals.Writing

  def model, do: TravelingPoet.Evals.ImageJudge.model()

  @doc "`{:ok, %{\"broken\", \"examples\", \"fluency\", \"reason\"}}` or `{:error, reason}`."
  def language(page, language, opts \\ []) do
    messages = [
      %{role: "system", content: system_prompt(language)},
      %{role: "user", content: render(page)}
    ]

    with {:ok, %{content: raw}} <-
           Writing.chat(model(), messages, Keyword.put(opts, :json, true)) do
      parse_response(raw)
    end
  end

  @doc false
  def parse_response(raw) when is_binary(raw) do
    json =
      case Regex.run(~r/\{.*\}/s, raw) do
        [obj] -> obj
        nil -> raw
      end

    with {:ok, v} <- Jason.decode(json),
         b when is_integer(b) <- v["broken"],
         f when is_integer(f) <- v["fluency"] do
      {:ok,
       %{
         "broken" => max(b, 0),
         "fluency" => f |> max(1) |> min(5),
         "examples" => v["examples"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.take(5),
         "reason" => v["reason"] |> to_string() |> String.slice(0, 300)
       }}
    else
      _ -> {:error, :unparseable}
    end
  end

  def parse_response(_), do: {:error, :unparseable}

  @doc false
  def render(page) do
    sections =
      Enum.map_join(page["sections"], "\n\n", fn s ->
        "## #{s["kind"]}#{if s["title"] != "", do: ": " <> s["title"]}\n#{s["body"]}"
      end)

    "# #{page["title"]}\n#{page["teaser"]}\n\n#{sections}"
  end

  defp system_prompt(language) do
    name = TravelingPoet.Locale.name(language) || "English"

    """
    You are a native #{name} editor. You read one page of a travel journal written in
    #{name} and check only its language, not its facts or its taste.

    Reply with one JSON object:
    {"broken": n,        // sentences that are not grammatical, natural #{name}: invented or
                         // garbled words, words from another language dropped mid-sentence
                         // (a foreign proper name is fine), wrong gender or agreement,
                         // calques that a native reader would stumble on, sentences that
                         // make no sense
     "examples": [..],   // up to 5 of those sentences, quoted exactly
     "fluency": 1-5,     // 5 = reads as if a good native writer wrote it; 1 = hard to read
     "reason": "one sentence"}

    Poems may bend grammar on purpose; count a line of verse only when it is broken,
    not when it is poetic.
    """
  end
end
