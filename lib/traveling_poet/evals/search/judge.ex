defmodule TravelingPoet.Evals.Search.Judge do
  @moduledoc """
  Scores one search result for the search eval, blind to the provider.

  The rubric is what a poet needs from `web_search`: specific, named facts it
  can cite, and URLs worth fetching next (a Commons file page, an official
  site, a programme page). A fluent answer with nothing checkable in it
  scores low; a list of the right pages with thin snippets can score well.

  Eval-only, like `Evals.ImageJudge`.
  """

  @api_url "https://openrouter.ai/api/v1/chat/completions"
  @max_chars 12_000

  def model, do: TravelingPoet.Evals.ImageJudge.model()

  def score(query, result, opts \\ []) do
    key = Keyword.get(opts, :api_key, Application.get_env(:traveling_poet, :openrouter_api_key))
    today = Keyword.get(opts, :today, Date.utc_today())

    if key in [nil, ""] do
      {:error, :not_configured}
    else
      body = %{
        model: model(),
        messages: [
          %{role: "system", content: system_prompt(today)},
          %{role: "user", content: user_prompt(query, result)}
        ],
        response_format: %{type: "json_object"}
      }

      req_opts =
        [
          json: body,
          headers: [{"authorization", "Bearer #{key}"}],
          receive_timeout: 120_000,
          retry: :transient
        ] ++ Application.get_env(:traveling_poet, :eval_req_options, [])

      case Req.post(@api_url, req_opts) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => raw}} | _]}}} ->
          parse_response(raw)

        {:ok, %{status: status}} ->
          {:error, "judge returned #{status}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
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
         a when is_integer(a) <- v["answers"],
         f when is_integer(f) <- v["specific_facts"] do
      {:ok,
       %{
         "answers" => clamp(a),
         "specific_facts" => max(f, 0),
         "sourced" => score_or_nil(v["sourced"]),
         "current" => score_or_nil(v["current"]),
         "right_urls" => score_or_nil(v["right_urls"]),
         "suspect" => v["suspect"] |> List.wrap() |> Enum.filter(&is_binary/1),
         "reason" => v["reason"] |> to_string() |> String.slice(0, 300)
       }}
    else
      _ -> {:error, :unparseable}
    end
  end

  def parse_response(_), do: {:error, :unparseable}

  defp clamp(n), do: n |> max(1) |> min(5)
  defp score_or_nil(n) when is_integer(n), do: clamp(n)
  defp score_or_nil(_), do: nil

  @doc false
  def render(result) do
    answer = if result["answer"] in [nil, ""], do: "(none)", else: result["answer"]

    sources =
      result["results"]
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {r, i} ->
        [
          "[#{i}] #{r["url"]}",
          r["title"] && "    title: #{r["title"]}",
          r["published"] && "    published: #{r["published"]}",
          r["snippet"] && "    snippet: #{r["snippet"]}"
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
      end)

    "ANSWER:\n#{answer}\n\nSOURCES:\n#{if sources == "", do: "(none)", else: sources}"
    |> String.slice(0, @max_chars)
  end

  defp system_prompt(today) do
    """
    You grade one web search result for a travel writer who researches a place or a
    topic, cites sources, and may fetch the listed URLs next. Today is #{Date.to_iso8601(today)}.
    You do not know which search engine produced it. The result has an optional
    synthesized ANSWER and a list of SOURCES (URLs, sometimes with snippets).

    Reply with one JSON object:
    {"answers": 1-5,          // does it answer what the query asks for?
     "specific_facts": n,     // count of distinct specific, checkable facts that answer the query:
                              // named places, addresses, dates, opening times, programme items,
                              // figures. Generic description does not count.
     "sourced": 1-5 or null,  // can those facts be traced to a listed URL or snippet? null if no facts
     "current": 1-5 or null,  // only when the query asks for current or dated things (this week,
                              // this month, 2026, weather): are the dates right for today? else null
     "right_urls": 1-5 or null, // when the query hunts for a kind of page (a Wikimedia Commons file
                              // page, an official site, an address, a programme page): are those
                              // pages among the SOURCES? else null
     "suspect": [strings],    // facts that look invented, stale, or contradict the sources
     "reason": "one sentence"}

    A search engine that returns the right pages with thin snippets is useful: the writer
    will fetch them. An answer that sounds complete but cites nothing checkable is not.
    """
  end

  defp user_prompt(query, result) do
    params =
      [
        query["count"] && "count=#{query["count"]}",
        query["freshness"] && "freshness=#{query["freshness"]}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "QUERY: #{query["query"]}#{if params != "", do: " (#{params})"}\n\n#{render(result)}"
  end
end
