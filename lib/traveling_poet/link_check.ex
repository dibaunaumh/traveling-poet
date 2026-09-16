defmodule TravelingPoet.LinkCheck do
  @moduledoc """
  Reachability check for agent-cited URLs (kindness opportunities,
  illustration source links). Agents hallucinate plausible-looking domains —
  a beta entry cited a museum donation link on a domain that doesn't resolve.
  User-facing links must at least be alive.

  This is a liveness check, not an endorsement: a parked domain still passes.
  The skill-side rule ("only cite URLs from pages you actually fetched")
  covers semantic correctness; this covers the dead ones.

  A site that refuses non-browser clients (401, 403, 429 on both HEAD and
  GET) tells us nothing about whether the page exists: openai.com answers 403
  for any path, real or made up. Those count as unknown and pass, so a real
  article is never dropped for its host's bot wall. 404, 410, 5xx and hosts
  that do not resolve are still dead.
  """

  require Logger

  @timeout_ms 6_000
  # Answers that say "not for you", not "not here".
  @bot_walls [401, 403, 429]
  # basic SSRF hygiene: the app fetches agent-supplied URLs
  @blocked_host_suffixes [".internal", ".local", ".localhost"]

  @doc "Validates a list of URLs; returns :ok or {:error, [bad_urls]}."
  def validate_all(urls) when is_list(urls) do
    bad =
      urls
      |> Enum.uniq()
      |> Enum.take(8)
      |> Enum.reject(&(check(&1) == :ok))

    if bad == [], do: :ok, else: {:error, bad}
  end

  @doc "Checks a single URL: scheme, host sanity, then a HEAD/GET probe."
  def check(url) when is_binary(url) do
    with %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) <-
           URI.parse(url),
         :ok <- check_host(host) do
      probe(url)
    else
      _ -> {:error, :invalid_url}
    end
  end

  def check(_), do: {:error, :invalid_url}

  defp check_host(host) do
    cond do
      host in ["localhost", "127.0.0.1", "[::1]"] ->
        {:error, :blocked_host}

      Enum.any?(@blocked_host_suffixes, &String.ends_with?(host, &1)) ->
        {:error, :blocked_host}

      # literal IPs (v4-ish or bracketed v6) — public sites cite hostnames
      host =~ ~r/^\d+\.\d+\.\d+\.\d+$/ or String.starts_with?(host, "[") ->
        {:error, :blocked_host}

      true ->
        :ok
    end
  end

  # In test every probe goes through a Req.Test stub (config/test.exs): the
  # suite must never depend on a real host being up.
  defp req_options, do: Application.get_env(:traveling_poet, :link_check_req_options, [])

  defp probe(url) do
    case Req.head(
           url,
           [receive_timeout: @timeout_ms, redirect: true, retry: false] ++ req_options()
         ) do
      {:ok, %{status: status}} when status in 200..399 ->
        :ok

      # some servers reject HEAD; retry as a cheap GET
      {:ok, %{status: status}} when status in [401, 403, 405, 429, 501] ->
        probe_get(url)

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.debug("LinkCheck: #{url} unreachable: #{inspect(reason)}")
        {:error, :unreachable}
    end
  end

  defp probe_get(url) do
    case Req.get(
           url,
           [receive_timeout: @timeout_ms, redirect: true, retry: false] ++ req_options()
         ) do
      {:ok, %{status: status}} when status in 200..399 ->
        :ok

      {:ok, %{status: status}} when status in @bot_walls ->
        Logger.debug(
          "LinkCheck: #{url} refused a non-browser client (#{status}); counting as unknown"
        )

        :ok

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, _} ->
        {:error, :unreachable}
    end
  end
end
