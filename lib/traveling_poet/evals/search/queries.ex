defmodule TravelingPoet.Evals.Search.Queries do
  @moduledoc """
  Collects the `web_search` calls poets actually made, from the OpenClaw
  session transcripts on their sprites (`~/.openclaw/agents/*/sessions/`,
  where the gateway keeps about five days, current plus `.reset.*` files).

  Read-only: one `grep` per sprite over `SpritesClient.exec`. It does wake
  each sprite for a few seconds.
  """

  alias TravelingPoet.SpritesClient

  @call ~r/"name":"(web_search|web_fetch)","arguments":(\{[^{}]*\})/

  @doc """
  Returns `%{calls: [%{sprite, file, tool, arguments}], errors: [{sprite, reason}]}`.
  """
  def collect(sprite_names) when is_list(sprite_names) do
    cmd =
      ~S"""
      cd ~/.openclaw/agents 2>/dev/null && grep -o -H -E '"name":"(web_search|web_fetch)","arguments":\{[^{}]*\}' */sessions/*.jsonl* 2>/dev/null
      """

    Enum.reduce(sprite_names, %{calls: [], errors: []}, fn name, acc ->
      case SpritesClient.exec(name, cmd) do
        {:ok, out} ->
          %{acc | calls: acc.calls ++ parse(name, printable(out))}

        {:error, reason} ->
          %{acc | errors: acc.errors ++ [{name, inspect(reason)}]}
      end
    end)
  end

  @doc false
  def parse(sprite, text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      with [file, rest] <- String.split(line, ":", parts: 2),
           [_, tool, args] <- Regex.run(@call, rest),
           {:ok, arguments} <- Jason.decode(args) do
        [%{sprite: sprite, file: Path.basename(file), tool: tool, arguments: arguments}]
      else
        _ -> []
      end
    end)
  end

  @doc """
  Per transcript file: how many searches and fetches one session made. A
  session is roughly one day of a poet's life (the daily run plus chat).
  """
  def per_session(calls) do
    calls
    |> Enum.group_by(&{&1.sprite, &1.file})
    |> Enum.map(fn {{sprite, file}, cs} ->
      %{
        sprite: sprite,
        file: file,
        searches: Enum.count(cs, &(&1.tool == "web_search")),
        fetches: Enum.count(cs, &(&1.tool == "web_fetch"))
      }
    end)
  end

  @doc """
  A fixed replay set: up to `per_sprite` distinct queries from each sprite,
  picked by a hash of the query so the choice is stable across runs.
  """
  def sample(calls, per_sprite) do
    calls
    |> Enum.filter(&(&1.tool == "web_search" and is_binary(&1.arguments["query"])))
    |> Enum.uniq_by(&normalize(&1.arguments["query"]))
    |> Enum.group_by(& &1.sprite)
    |> Enum.sort()
    |> Enum.flat_map(fn {_sprite, cs} ->
      cs
      |> Enum.sort_by(&:crypto.hash(:sha256, &1.arguments["query"]))
      |> Enum.take(per_sprite)
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {c, i} ->
      %{
        "id" => "q#{String.pad_leading(Integer.to_string(i), 2, "0")}",
        "query" => c.arguments["query"],
        "count" => c.arguments["count"],
        "freshness" => c.arguments["freshness"]
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)
    end)
  end

  defp normalize(q), do: q |> String.downcase() |> String.replace(~r/\W+/u, " ") |> String.trim()

  # Sprite exec output carries stream-frame control bytes around stdout.
  defp printable(data) when is_binary(data) do
    data |> :binary.bin_to_list() |> Enum.filter(&(&1 >= 32 or &1 == 10)) |> :binary.list_to_bin()
  end

  defp printable(other), do: to_string(other)
end
