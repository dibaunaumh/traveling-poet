defmodule TravelingPoet.AppLoop.Web do
  @moduledoc """
  `web_search` and `web_fetch` done by the app, for an app-side poet loop.

  On a sprite these are OpenClaw built-ins: search asks the Perplexity model
  (`Provisioner.search_model/0`) through OpenRouter, fetch reads a page into
  text. Here search is the same model on the same key, so the two loops
  research alike; fetch reads the page on the server.

  Fetch is the one place the app requests a URL a model chose, so it keeps
  `LinkCheck`'s host rules (no localhost, no `.internal`, no literal IPs) on
  the URL and on every redirect, caps the bytes it reads, and returns text
  only. Text extraction is deliberately plain (drop scripts, styles and page
  chrome, keep paragraph breaks, prefer `<article>` or `<main>`): the app
  has no HTML parser in production, and a poet reads for facts, not layout.
  """

  alias TravelingPoet.{LinkCheck, Provisioner}

  @api_url "https://openrouter.ai/api/v1/chat/completions"
  @max_bytes 2_000_000
  @default_chars 12_000

  @doc "One search: `{:ok, %{answer, citations, cost}}` or `{:error, reason}`."
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) and query != "" do
    key = Keyword.get(opts, :api_key, Application.get_env(:traveling_poet, :openrouter_api_key))

    if key in [nil, ""] do
      {:error, :not_configured}
    else
      body = %{
        model: Provisioner.search_model(),
        messages: [%{role: "user", content: query}],
        usage: %{include: true}
      }

      case Req.post(
             @api_url,
             [json: body, headers: [{"authorization", "Bearer #{key}"}]] ++ req_options()
           ) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => msg} | _]} = b}} ->
          {:ok,
           %{
             answer: msg["content"] || "",
             citations: citations(b, msg),
             cost: get_in(b, ["usage", "cost"])
           }}

        {:ok, %{status: status, body: b}} ->
          {:error, "search failed: #{status} #{b |> inspect() |> String.slice(0, 200)}"}

        {:error, reason} ->
          {:error, "search failed: #{inspect(reason)}"}
      end
    end
  end

  def search(_query, _opts), do: {:error, "query is required"}

  # Perplexity on OpenRouter returns its sources as top-level `citations`
  # (older) or as url_citation annotations on the message (newer).
  defp citations(body, msg) do
    from_annotations =
      for %{"type" => "url_citation", "url_citation" => %{"url" => url} = c} <-
            msg["annotations"] || [] do
        %{url: url, title: c["title"]}
      end

    case from_annotations do
      [] -> Enum.map(body["citations"] || [], &%{url: &1})
      list -> Enum.uniq_by(list, & &1.url)
    end
  end

  @doc """
  One page as text: `{:ok, %{url, status, title, text, truncated}}` or
  `{:error, reason}`.
  """
  def fetch(url, opts \\ []) do
    max_chars = Keyword.get(opts, :max_chars, @default_chars)

    with :ok <- allowed(url),
         {:ok, resp} <- get(url, 0) do
      html = resp.body |> to_string() |> binary_slice(0, @max_bytes)
      text = if html?(resp), do: html_to_text(html), else: html
      clipped = String.slice(text, 0, max_chars)

      {:ok,
       %{
         url: url,
         status: resp.status,
         title: title(html),
         text: clipped,
         truncated: String.length(text) > max_chars
       }}
    end
  end

  @doc """
  Whether the app may request this URL: LinkCheck's host rules, and the
  name must not resolve into a private, loopback or link-local network
  (Fly's own network is IPv6 `fdaa::/16`, its metadata `169.254.x`). Unlike
  a liveness probe, a fetch hands the body to the model, so a public name
  pointed at an internal address must not get through.
  """
  def allowed(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "" ->
        cond do
          LinkCheck.blocked_host?(h) -> {:error, "that host is not allowed"}
          resolves_inside?(h) -> {:error, "that host is not allowed"}
          true -> :ok
        end

      _ ->
        {:error, "not an http(s) URL"}
    end
  end

  def allowed(_), do: {:error, "url is required"}

  defp resolves_inside?(host) do
    resolver = Application.get_env(:traveling_poet, :app_loop_resolver, &resolve/1)
    Enum.any?(resolver.(host), &internal_ip?/1)
  end

  @doc false
  # The test resolver: the suite never touches DNS.
  def no_addresses(_host), do: []

  defp resolve(host) do
    name = String.to_charlist(host)

    for family <- [:inet, :inet6],
        {:ok, ips} <- [:inet.getaddrs(name, family)],
        ip <- ips,
        do: ip
  end

  @doc false
  def internal_ip?({10, _, _, _}), do: true
  def internal_ip?({127, _, _, _}), do: true
  def internal_ip?({0, _, _, _}), do: true
  def internal_ip?({169, 254, _, _}), do: true
  def internal_ip?({172, b, _, _}) when b in 16..31, do: true
  def internal_ip?({192, 168, _, _}), do: true
  def internal_ip?({100, b, _, _}) when b in 64..127, do: true
  def internal_ip?({0, 0, 0, 0, 0, 0, 0, _}), do: true

  def internal_ip?({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do: internal_ip?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  def internal_ip?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  def internal_ip?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true
  def internal_ip?(_), do: false

  # Redirects are followed by hand so every hop passes `allowed/1`.
  defp get(_url, 5), do: {:error, "too many redirects"}

  defp get(url, hops) do
    case Req.get(
           url,
           [
             redirect: false,
             retry: false,
             receive_timeout: 15_000,
             decode_body: false,
             headers: [{"user-agent", "Mozilla/5.0 (compatible; TravelingPoet/1.0)"}]
           ] ++ req_options()
         ) do
      {:ok, %{status: status} = resp} when status in [301, 302, 303, 307, 308] ->
        with [location | _] <- Req.Response.get_header(resp, "location"),
             next = URI.merge(url, location) |> to_string(),
             :ok <- allowed(next) do
          get(next, hops + 1)
        else
          [] -> {:error, "redirect without a location"}
          error -> error
        end

      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, resp}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, "unreachable: #{inspect(reason)}"}
    end
  end

  defp html?(resp) do
    case Req.Response.get_header(resp, "content-type") do
      [ct | _] -> String.contains?(ct, "html")
      [] -> true
    end
  end

  defp title(html) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, html) do
      [_, t] -> t |> decode_entities() |> String.trim()
      _ -> nil
    end
  end

  @doc "Readable text of an HTML page."
  def html_to_text(html) do
    html
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/<head\b.*?<\/head>/is, "")
    |> String.replace(~r/<(script|style|noscript|svg|template|iframe)\b.*?<\/\1>/is, "")
    |> main_part()
    |> String.replace(~r/<(nav|footer|header|aside|form)\b.*?<\/\1>/is, "")
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/(p|div|h[1-6]|li|tr|section|article|blockquote|pre|dd|dt)>/i, "\n\n")
    |> String.replace(~r/<li\b[^>]*>/i, "- ")
    |> String.replace(~r/<[^>]+>/, "")
    |> decode_entities()
    |> String.replace(~r/[ \t\x{00A0}]+/u, " ")
    |> String.replace(~r/ *\n */, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  # The article when the page marks one, else the main, else the body.
  defp main_part(html) do
    Enum.find_value(
      [~r/<article\b[^>]*>(.*)<\/article>/is, ~r/<main\b[^>]*>(.*)<\/main>/is],
      html,
      fn re ->
        case Regex.run(re, html) do
          [_, inner] -> if String.length(inner) > 500, do: inner
          _ -> nil
        end
      end
    )
  end

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " ",
    "mdash" => "—",
    "ndash" => "–",
    "hellip" => "…",
    "rsquo" => "’",
    "lsquo" => "‘",
    "rdquo" => "”",
    "ldquo" => "“",
    "laquo" => "«",
    "raquo" => "»",
    "eacute" => "é",
    "egrave" => "è",
    "agrave" => "à",
    "ccedil" => "ç",
    "uuml" => "ü",
    "ouml" => "ö",
    "auml" => "ä",
    "szlig" => "ß",
    "copy" => "©",
    "deg" => "°",
    "middot" => "·"
  }

  defp decode_entities(text) do
    Regex.replace(~r/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/, text, fn whole, code ->
      case code do
        "#x" <> hex -> codepoint(Integer.parse(hex, 16), whole)
        "#" <> dec -> codepoint(Integer.parse(dec), whole)
        name -> Map.get(@entities, name, whole)
      end
    end)
  end

  defp codepoint({n, ""}, _whole) when n > 0 and n < 0x110000 and n not in 0xD800..0xDFFF,
    do: <<n::utf8>>

  defp codepoint(_, whole), do: whole

  # In test every request goes through a Req.Test stub (config/test.exs).
  defp req_options, do: Application.get_env(:traveling_poet, :app_loop_req_options, [])
end
