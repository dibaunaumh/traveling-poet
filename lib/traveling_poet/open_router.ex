defmodule TravelingPoet.OpenRouter do
  @moduledoc """
  The fleet's budget, as OpenRouter sees it.

  Every poet's model turn runs on one OpenRouter key. When that key hits its
  monthly limit, OpenRouter rejects each request with a 402 *before generating
  anything* — the agent emits no text, the gateway relays nothing, and the app
  sees only a silent sprite that times out ten minutes later. On 2026-08-30
  that took four poets off the road while every app-side signal said "no
  reply", so this module asks OpenRouter directly and lets the answer surface
  on /admin and in the health alert.
  """

  require Logger

  @key_url "https://openrouter.ai/api/v1/key"

  @doc """
  Credit status for the configured key:

      {:ok, %{usage: 12.34, limit: 20.0, remaining: 7.66, exhausted?: false}}

  `limit` is nil for keys with no monthly cap, and then `remaining` is nil and
  `exhausted?` is false. Returns `{:error, reason}` when the key is unset or
  OpenRouter can't be reached — callers treat that as "unknown", not "fine".
  """
  def key_status do
    key = Application.get_env(:traveling_poet, :openrouter_api_key)

    if key in [nil, ""] do
      {:error, :not_configured}
    else
      request(key)
    end
  end

  defp request(key) do
    case Req.get(@key_url,
           headers: [{"authorization", "Bearer #{key}"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, summarize(data)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("OpenRouter key check failed (#{status}): #{inspect(body)}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.warning("OpenRouter key check failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp summarize(data) do
    usage = as_float(Map.get(data, "usage"))
    limit = as_float(Map.get(data, "limit"))
    remaining = limit && usage && Float.round(limit - usage, 4)

    %{
      usage: usage,
      limit: limit,
      remaining: remaining,
      # A key can't buy a full turn well before it reads zero: OpenRouter
      # rejects a request whose max_tokens costs more than what is left, so
      # "nearly empty" is already "off the road".
      exhausted?: remaining != nil and remaining <= 0.0,
      low?: remaining != nil and remaining <= low_threshold()
    }
  end

  defp as_float(nil), do: nil
  defp as_float(n) when is_float(n), do: n
  defp as_float(n) when is_integer(n), do: n * 1.0

  defp as_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp as_float(_), do: nil

  # Dollars of headroom under which the fleet is one busy day from stalling.
  defp low_threshold do
    Application.get_env(:traveling_poet, :openrouter_low_credit_dollars, 2.0)
  end
end
