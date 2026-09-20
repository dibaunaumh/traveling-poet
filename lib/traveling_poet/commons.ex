defmodule TravelingPoet.Commons do
  @moduledoc """
  Finds reference photos on Wikimedia Commons for a poet's drawings.

  A quarter of the fleet's `web_search` calls were Commons hunts ("site:
  commons.wikimedia.org ...", "filetype:jpg"), each a paid Sonar call that
  answered with prose and rarely with a file page. The 2026-09-18 search
  replay scored both Sonar models 1.5/5 on them. The Commons API answers
  the same question for free with exactly what the skill asks for: file page
  URLs (`https://commons.wikimedia.org/wiki/File:...`), with licence and
  author.

  Two ways in, merged: a text search over file pages, and, given
  coordinates, the photos taken near that point. No key; Wikimedia only asks
  for a descriptive User-Agent.
  """

  require Logger

  @api_url "https://commons.wikimedia.org/w/api.php"
  @user_agent "TravelingPoet/1.0 (https://poet.travel)"
  @bitmaps ~w(image/jpeg image/png image/webp image/tiff)
  @max_limit 10
  @max_radius_m 10_000

  @doc """
  Returns `{:ok, [photo]}` or `{:error, reason}`.

  Options: `:lat`, `:lng` (photos taken nearby), `:radius_m` (default 1000,
  at most 10000), `:limit` (default 6, at most 10). A query, coordinates, or
  both are needed.

  Each photo: `title`, `page_url` (the file page, the URL to cite),
  `thumb_url`, `description`, `author`, `license`, `date`, `width`,
  `height`, and `distance_m` when found by coordinates.
  """
  def search(query, opts \\ []) do
    query = clean_query(query)
    limit = opts |> Keyword.get(:limit, 6) |> clamp(1, @max_limit)
    lat = Keyword.get(opts, :lat)
    lng = Keyword.get(opts, :lng)
    near? = is_number(lat) and is_number(lng)

    if query == "" and not near? do
      {:error, "a query or lat/lng is required"}
    else
      searches =
        [
          query != "" && text_params(query, limit),
          near? &&
            geo_params(
              lat,
              lng,
              opts |> Keyword.get(:radius_m, 1000) |> clamp(10, @max_radius_m),
              limit
            )
        ]
        |> Enum.filter(& &1)

      results = Enum.map(searches, &fetch/1)

      case Enum.filter(results, &match?({:ok, _}, &1)) do
        [] ->
          hd(results)

        oks ->
          photos =
            oks
            |> Enum.flat_map(fn {:ok, photos} -> photos end)
            |> Enum.uniq_by(& &1.page_url)
            |> Enum.take(limit)

          {:ok, photos}
      end
    end
  end

  @doc false
  # Poets learned web-search habits for this ("site:commons.wikimedia.org",
  # "filetype:jpg", "File:"); they mean nothing to the Commons search itself.
  def clean_query(query) when is_binary(query) do
    query
    |> String.replace(~r/\b(site|filetype|inurl):\S+/i, " ")
    |> String.replace(~r/\b(commons\.)?wikimedia(\.org)?\b|\bcommons\b|\bFile:/i, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def clean_query(_), do: ""

  defp text_params(query, limit) do
    %{
      generator: "search",
      gsrsearch: query <> " filetype:bitmap",
      gsrnamespace: 6,
      gsrlimit: limit
    }
  end

  defp geo_params(lat, lng, radius, limit) do
    %{
      generator: "geosearch",
      ggscoord: "#{lat}|#{lng}",
      ggsradius: radius,
      ggsnamespace: 6,
      ggslimit: limit,
      codistancefrompoint: "#{lat}|#{lng}"
    }
  end

  defp fetch(params) do
    params =
      Map.merge(params, %{
        action: "query",
        format: "json",
        formatversion: 2,
        prop: "imageinfo|coordinates",
        iiprop: "url|size|mime|extmetadata",
        iiurlwidth: 640,
        iiextmetadatafilter: "ImageDescription|Artist|LicenseShortName|DateTimeOriginal"
      })

    opts =
      [
        params: params,
        headers: [{"user-agent", @user_agent}],
        receive_timeout: 15_000,
        retry: :transient
      ] ++ Application.get_env(:traveling_poet, :commons_req_options, [])

    case Req.get(@api_url, opts) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse(body)}

      {:ok, %{status: status}} ->
        Logger.warning("Commons: API returned #{status}")
        {:error, "Commons API returned #{status}"}

      {:error, reason} ->
        Logger.warning("Commons: request failed: #{inspect(reason)}")
        {:error, "Commons API request failed"}
    end
  end

  @doc false
  def parse(%{"query" => %{"pages" => pages}}) when is_list(pages) do
    pages
    |> Enum.sort_by(&(&1["index"] || 0))
    |> Enum.flat_map(fn page ->
      with [info | _] <- page["imageinfo"] || [],
           true <- info["mime"] in @bitmaps,
           url when is_binary(url) <- info["descriptionurl"] do
        meta = info["extmetadata"] || %{}

        [
          %{
            title: page["title"] |> to_string() |> String.replace_prefix("File:", ""),
            page_url: url,
            thumb_url: info["thumburl"],
            description: meta_text(meta, "ImageDescription", 240),
            author: meta_text(meta, "Artist", 80),
            license: meta_text(meta, "LicenseShortName", 40),
            date: meta_text(meta, "DateTimeOriginal", 40),
            width: info["width"],
            height: info["height"],
            distance_m: distance(page)
          }
          |> Map.reject(fn {_k, v} -> v in [nil, ""] end)
        ]
      else
        _ -> []
      end
    end)
  end

  def parse(_), do: []

  defp distance(%{"coordinates" => [%{"dist" => d} | _]}) when is_number(d), do: round(d)
  defp distance(_), do: nil

  # extmetadata values are HTML fragments ("<a href=...>Name</a>")
  defp meta_text(meta, key, max) do
    case get_in(meta, [key, "value"]) do
      v when is_binary(v) ->
        v
        |> String.replace(~r/<[^>]*>/, "")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, max)

      _ ->
        nil
    end
  end

  defp clamp(n, lo, hi) when is_number(n), do: n |> round() |> max(lo) |> min(hi)
  defp clamp(_, lo, _hi), do: lo
end
