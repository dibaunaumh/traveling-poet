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
  @credits_url "https://openrouter.ai/api/v1/credits"

  @doc """
  Credit status for the configured key:

      {:ok, %{usage: 12.34, limit: 20.0, remaining: 7.66, exhausted?: false,
              low?: false, scope: :key, account_remaining: 58.4}}

  `remaining` is whichever runs out first: the key's own monthly allowance
  (`limit_remaining` as OpenRouter reports it) or the account's prepaid
  credits; `scope` says which. `limit` is nil for a key with no monthly cap
  and no readable account balance, and then `remaining` is nil and
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
    case get(@key_url, key) do
      {:ok, %{"data" => data}} -> {:ok, summarize(data, credits(key))}
      error -> error
    end
  end

  # The account balance is a second call and a nice-to-have: without it the
  # key's own allowance still answers.
  defp credits(key) do
    case get(@credits_url, key) do
      {:ok, %{"data" => data}} -> data
      _ -> nil
    end
  end

  defp get(url, key) do
    case Req.get(url, headers: [{"authorization", "Bearer #{key}"}], receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("OpenRouter check #{url} failed (#{status}): #{inspect(body)}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.warning("OpenRouter check #{url} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  # `usage` on /key is the key's lifetime spend, `limit` its monthly cap:
  # the two are not comparable, and `limit - usage` went negative for good
  # once the key had ever spent more than one month's cap. That paged Udi
  # "OUT of credit" every day of October 2026 with $58 in the account.
  # OpenRouter says what is left itself (`limit_remaining`, reset monthly),
  # and the account balance is `total_credits - total_usage` on /credits.
  def summarize(data, credits \\ nil) do
    limit = as_float(Map.get(data, "limit"))

    usage =
      if Map.get(data, "limit_reset") == "monthly",
        do: as_float(Map.get(data, "usage_monthly")) || as_float(Map.get(data, "usage")),
        else: as_float(Map.get(data, "usage"))

    key_remaining =
      case as_float(Map.get(data, "limit_remaining")) do
        nil -> limit && usage && Float.round(limit - usage, 4)
        left -> Float.round(left, 4)
      end

    account_remaining =
      with %{} <- credits,
           total when is_float(total) <- as_float(Map.get(credits, "total_credits")),
           used when is_float(used) <- as_float(Map.get(credits, "total_usage")) do
        Float.round(total - used, 4)
      else
        _ -> nil
      end

    {scope, remaining, cap} =
      case {key_remaining, account_remaining} do
        {nil, nil} -> {:key, nil, limit}
        {k, nil} -> {:key, k, limit}
        {nil, a} -> {:account, a, as_float(Map.get(credits, "total_credits"))}
        {k, a} when a < k -> {:account, a, as_float(Map.get(credits, "total_credits"))}
        {k, _} -> {:key, k, limit}
      end

    %{
      usage: usage,
      limit: cap,
      remaining: remaining,
      scope: scope,
      account_remaining: account_remaining,
      # A key can't buy a full turn well before it reads zero: OpenRouter
      # rejects a request whose max_tokens costs more than what is left, so
      # "nearly empty" is already "off the road".
      exhausted?: remaining != nil and remaining <= 0.0,
      low?: remaining != nil and remaining <= low_threshold()
    }
  end

  @doc "What `remaining` is counting down: the key's monthly allowance or the account's credits."
  def scope_label(%{scope: :account}), do: "account credits"
  def scope_label(_), do: "key allowance (monthly)"

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
