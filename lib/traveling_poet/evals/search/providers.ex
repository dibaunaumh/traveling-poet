defmodule TravelingPoet.Evals.Search.Providers do
  @moduledoc """
  The search backends the fleet could run `web_search` on, called directly
  with the request OpenClaw 2026.4.9 sends for each (read from its bundled
  providers), so a replay sees what a poet would have seen.

    * Sonar (`perplexity/sonar-pro`, `perplexity/sonar`) over OpenRouter chat
      completions: `messages: [user: query]`, plus `search_recency_filter`
      when the agent passed `freshness`. One synthesized answer, with
      citations from `citations` or `url_citation` annotations.
    * Tavily `/search`: `query`, `max_results` (the agent's `count`, default
      5). OpenClaw's `web_search` never sets `search_depth`, so it always
      runs basic; `:tavily_advanced` is here only to see what advanced
      would buy through the separate `tavily_search` tool. Freshness is not
      forwarded by OpenClaw's Tavily provider either.

  Eval-only. Nothing in the request path calls this module.
  """

  @openrouter_url "https://openrouter.ai/api/v1/chat/completions"
  @tavily_url "https://api.tavily.com/search"

  @providers [:sonar_pro, :sonar, :tavily_basic, :tavily_advanced]

  def all, do: @providers

  def parse!(names) when is_binary(names) do
    names
    |> String.split(",", trim: true)
    |> Enum.map(fn n ->
      atom = String.to_existing_atom(n)
      if atom in @providers, do: atom, else: raise(ArgumentError)
    end)
  rescue
    ArgumentError ->
      reraise ArgumentError,
              "unknown provider in #{inspect(names)}; known: #{Enum.join(@providers, ",")}",
              __STACKTRACE__
  end

  @doc "Whether this provider's key is configured."
  def configured?(p) when p in [:sonar_pro, :sonar], do: present?(openrouter_key())
  def configured?(p) when p in [:tavily_basic, :tavily_advanced], do: present?(tavily_key())

  @doc """
  Runs one query. `query` is the replay entry (`"query"`, optional `"count"`
  and `"freshness"`).

  Returns `{:ok, %{answer, results: [%{url, title, snippet, published}],
  urls, cost, ms}}` or `{:error, reason}`. `cost` is USD: OpenRouter's
  reported cost for Sonar, credits times the configured per-credit rate for
  Tavily. `opts[:api_key]` overrides the configured key.
  """
  def search(provider, query, opts \\ [])

  def search(provider, %{"query" => q} = query, opts) when provider in [:sonar_pro, :sonar] do
    body =
      %{
        model: if(provider == :sonar_pro, do: "perplexity/sonar-pro", else: "perplexity/sonar"),
        messages: [%{role: "user", content: q}],
        usage: %{include: true}
      }
      |> maybe_put(:search_recency_filter, query["freshness"])

    timed(fn ->
      post(@openrouter_url, body, Keyword.get(opts, :api_key, openrouter_key()))
    end)
    |> case do
      {{:ok, resp}, ms} ->
        urls = sonar_citations(resp)

        {:ok,
         %{
           answer: get_in(resp, ["choices", Access.at(0), "message", "content"]),
           results: Enum.map(urls, &%{url: &1, title: nil, snippet: nil, published: nil}),
           urls: urls,
           cost: get_in(resp, ["usage", "cost"]),
           ms: ms
         }}

      {{:error, reason}, _ms} ->
        {:error, reason}
    end
  end

  def search(provider, %{"query" => q} = query, opts)
      when provider in [:tavily_basic, :tavily_advanced] do
    depth = if provider == :tavily_advanced, do: "advanced", else: "basic"

    body = %{
      query: q,
      max_results: query["count"] |> clamp_count(),
      search_depth: depth,
      include_usage: true
    }

    case timed(fn -> post(@tavily_url, body, Keyword.get(opts, :api_key, tavily_key())) end) do
      {{:ok, resp}, ms} ->
        results =
          for r <- resp["results"] || [], is_binary(r["url"]) do
            %{
              url: r["url"],
              title: r["title"],
              snippet: r["content"],
              published: r["published_date"]
            }
          end

        credits = get_in(resp, ["usage", "credits"]) || if(depth == "advanced", do: 2, else: 1)

        {:ok,
         %{
           answer: resp["answer"],
           results: results,
           urls: Enum.map(results, & &1.url),
           cost: credits * tavily_usd_per_credit(),
           ms: ms
         }}

      {{:error, reason}, _ms} ->
        {:error, reason}
    end
  end

  @doc false
  def sonar_citations(resp) do
    top = Enum.filter(resp["citations"] || [], &(is_binary(&1) and &1 != ""))

    if top != [] do
      Enum.uniq(top)
    else
      for choice <- resp["choices"] || [],
          a <- get_in(choice, ["message", "annotations"]) || [],
          a["type"] == "url_citation",
          url = get_in(a, ["url_citation", "url"]) || a["url"],
          is_binary(url),
          uniq: true,
          do: url
    end
  end

  defp clamp_count(n) when is_integer(n), do: n |> max(1) |> min(20)
  defp clamp_count(_), do: 5

  defp post(url, body, key) do
    if not present?(key) do
      {:error, :not_configured}
    else
      opts =
        [
          json: body,
          headers: [{"authorization", "Bearer #{key}"}],
          receive_timeout: 90_000,
          retry: :transient
        ] ++ Application.get_env(:traveling_poet, :eval_req_options, [])

      case Req.post(url, opts) do
        {:ok, %{status: 200, body: resp}} when is_map(resp) ->
          {:ok, resp}

        {:ok, %{status: status, body: resp}} ->
          {:error, "#{status}: #{inspect(resp, limit: 200)}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp timed(fun) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - t0}
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp present?(v), do: v not in [nil, ""]

  defp openrouter_key, do: Application.get_env(:traveling_poet, :openrouter_api_key)
  defp tavily_key, do: Application.get_env(:traveling_poet, :tavily_api_key)

  # Tavily pay-as-you-go: $0.008 per credit (basic search 1 credit, advanced 2).
  defp tavily_usd_per_credit,
    do: Application.get_env(:traveling_poet, :tavily_usd_per_credit, 0.008)
end
