defmodule TravelingPoet.AppLoop.Tools do
  @moduledoc """
  The tools an app-side poet loop offers the model (dec-024, option D).

  The descriptions and JSON schemas are not written twice: they are read out
  of the OpenClaw plugin the sprites run (`Provisioner.tpoet_plugin_source/2`),
  so a model sees exactly the words a sprite poet sees. What this module adds
  is how each tool is carried out without a sprite:

    * `:app` tools are the plugin's own: an HTTP call into `/api/agent/*`.
      `route/2` says which method, path and body, mirroring each plugin
      handler. `kind` says whether the call changes anything (`:write`) or
      only reads (`:read`); shadow runs never let a write reach the app.
    * `web_search` and `web_fetch` are what OpenClaw provides built in;
      `AppLoop.Web` does them on the server.
    * `read` opens a workspace file (a day file such as
      `skills/travel-and-journal/quiz.md`) from the files the run was given.

  `@not_offered` lists plugin tools a daily run has no use for. A new
  plugin tool must be routed or listed there (`app_loop_tools_test.exs`).
  """

  alias TravelingPoet.Provisioner

  @reads ~w(get_conversation_memory get_poet_context get_feedback journal_get_entry
            find_reference_photos get_book_context)

  # Uploading a file from the sprite's disk has no meaning without a disk;
  # the book has its own skill and its own turn.
  @not_offered ~w(journal_upload_illustration book_put_matter)

  @builtins [
    %{
      name: "web_search",
      description:
        "Search the web. Returns an answer synthesised from current web results, with the URLs it drew on. Use it to find pages, then web_fetch the ones you will cite.",
      parameters: %{
        type: "object",
        required: ["query"],
        properties: %{query: %{type: "string", description: "What to search for"}}
      }
    },
    %{
      name: "web_fetch",
      description:
        "Fetch a web page and return its readable text. Only cite pages you fetched and read.",
      parameters: %{
        type: "object",
        required: ["url"],
        properties: %{
          url: %{type: "string", description: "http or https URL"},
          maxChars: %{type: "number", description: "Cap on the text returned (default 12000)"}
        }
      }
    },
    %{
      name: "read",
      description:
        "Read a file from your workspace, e.g. skills/travel-and-journal/excursion.md, by its path relative to the workspace.",
      parameters: %{
        type: "object",
        required: ["path"],
        properties: %{path: %{type: "string"}}
      }
    }
  ]

  @doc "Names of the tools that are not `:app` tools."
  def builtin_names, do: Enum.map(@builtins, & &1.name)

  @doc "Plugin tools a daily run is not offered."
  def not_offered, do: @not_offered

  @doc """
  The tool list in OpenAI/OpenRouter function-calling form, plugin tools in
  plugin order, then the built-ins.
  """
  def definitions do
    plugin =
      for spec <- plugin_specs(), spec["name"] not in @not_offered do
        %{name: spec["name"], description: spec["description"], parameters: spec["parameters"]}
      end

    Enum.map(plugin ++ @builtins, fn t ->
      %{type: "function", function: Map.update!(t, :parameters, &normalize_parameters/1)}
    end)
  end

  @doc "`:read`, `:write`, `:builtin`, or `:unknown` for a tool name."
  def kind(name) when name in @reads, do: :read

  def kind(name) do
    cond do
      name in builtin_names() -> :builtin
      name in @not_offered -> :unknown
      name in Provisioner.tpoet_plugin_tools() -> :write
      true -> :unknown
    end
  end

  @doc """
  The `/api/agent` call a plugin tool makes, as `{method, path, body}`, the
  same as its handler in the plugin source. `nil` body means none.
  """
  def route(name, args) do
    date = args["entry_date"]

    case name do
      "get_conversation_memory" -> {:get, "/api/agent/memory", nil}
      "get_poet_context" -> {:get, "/api/agent/context", nil}
      "get_feedback" -> {:get, "/api/agent/feedback", nil}
      "record_preference" -> {:post, "/api/agent/preferences", args}
      "update_location" -> {:post, "/api/agent/location", args}
      "hold_here" -> {:post, "/api/agent/hold", args}
      "insert_stop" -> {:post, "/api/agent/itinerary_stops", args}
      "propose_topic" -> {:post, "/api/agent/topics", args}
      "write_reader_note" -> {:post, "/api/agent/reader_note", args}
      "suggest_reader_note_line" -> {:post, "/api/agent/reader_note/suggestions", args}
      "ask_reader" -> {:post, "/api/agent/asks", args}
      "near_home_put" -> {:post, "/api/agent/near_home", args}
      "request_excursion" -> {:post, "/api/agent/excursions", args}
      "journal_upsert_entry" -> {:post, "/api/agent/journal_entries", args}
      "journal_put_sections" -> {:put, entry_path(date, "/sections"), take(args, ~w(sections))}
      "journal_put_places" -> {:put, entry_path(date, "/places"), take(args, ~w(places))}
      "journal_put_stay_areas" -> {:put, entry_path(date, "/stay_areas"), take(args, ~w(areas))}
      "journal_put_finds" -> finds_route(date, args)
      "journal_put_quiz" -> {:put, entry_path(date, "/quiz"), take(args, ~w(questions notes))}
      "generate_illustration" -> {:post, "/api/agent/illustrations", args}
      "find_reference_photos" -> {:get, "/api/agent/reference_photos?" <> query(args), nil}
      "journal_publish" -> {:post, entry_path(date, "/publish"), %{}}
      "journal_get_entry" -> {:get, entry_path(date, ""), nil}
      "get_book_context" -> {:get, "/api/agent/book_context" <> chapter(args), nil}
      _ -> nil
    end
  end

  defp finds_route(date, args),
    do: {:put, entry_path(date, "/finds"), take(args, ~w(finds destination_name destination_url))}

  defp entry_path(date, suffix), do: "/api/agent/journal_entries/#{date}#{suffix}"

  defp take(args, keys), do: Map.take(args, keys)

  defp query(args) do
    args
    |> Enum.reject(fn {_k, v} -> is_nil(v) or is_map(v) or is_list(v) end)
    |> URI.encode_query()
  end

  defp chapter(%{"chapter" => c}) when is_binary(c) and c != "", do: "?chapter=" <> URI.encode(c)
  defp chapter(_), do: ""

  # A plugin tool with no parameters is registered as `{}`; OpenClaw fills
  # in an empty object schema, and so must we.
  defp normalize_parameters(p) when p == %{}, do: %{type: "object", properties: %{}}
  defp normalize_parameters(p), do: p

  @doc """
  Every `registerTool({...})` in the plugin source as a map with `name`,
  `description` and `parameters`, its handler cut off. The plugin writes
  JavaScript object literals; `js_object_to_json/1` turns each into JSON.
  """
  def plugin_specs do
    :persistent_term.get({__MODULE__, :specs}, nil) ||
      tap(parse_plugin(Provisioner.tpoet_plugin_source("", "")), fn specs ->
        :persistent_term.put({__MODULE__, :specs}, specs)
      end)
  end

  @doc false
  def parse_plugin(source) do
    ~r/registerTool\(\{/
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{at, len}] ->
      # byte offsets: the descriptions carry multi-byte characters
      body = binary_part(source, at + len, byte_size(source) - at - len)
      [head | _] = String.split(body, ~r/,\s*execute:/, parts: 2)
      {:ok, spec} = Jason.decode(js_object_to_json("{" <> head <> "}"))
      spec
    end)
    |> Enum.filter(&is_binary(&1["name"]))
  end

  @doc """
  A JavaScript object literal (bare keys, double-quoted strings, trailing
  commas) as JSON. Keys are quoted and trailing commas dropped only outside
  strings, so a description that says `{wikipedia: ...}` stays as written.
  """
  def js_object_to_json(js), do: js |> String.to_charlist() |> convert([], false) |> to_string()

  defp convert([], acc, _in_string), do: Enum.reverse(acc)

  defp convert([?\\, c | rest], acc, true), do: convert(rest, [c, ?\\ | acc], true)
  defp convert([?" | rest], acc, in_string), do: convert(rest, [?" | acc], not in_string)
  defp convert([c | rest], acc, true), do: convert(rest, [c | acc], true)

  defp convert([?, | rest], acc, false) do
    case skip_ws(rest) do
      [c | _] when c in [?}, ?]] -> convert(rest, acc, false)
      _ -> convert(rest, [?, | acc], false)
    end
  end

  defp convert([c | _] = chars, acc, false) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {word, rest} =
      Enum.split_while(chars, &(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 == ?_))

    case skip_ws(rest) do
      [?: | _] -> convert(rest, Enum.reverse(~c"\"" ++ word ++ ~c"\"", acc), false)
      _ -> convert(rest, Enum.reverse(word, acc), false)
    end
  end

  defp convert([c | rest], acc, false), do: convert(rest, [c | acc], false)

  defp skip_ws([c | rest]) when c in [?\s, ?\n, ?\t, ?\r], do: skip_ws(rest)
  defp skip_ws(chars), do: chars
end
