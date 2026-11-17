defmodule TravelingPoet.AppLoop.Runner do
  @moduledoc """
  The agent loop of option D (dec-024): the app calls the model through
  OpenRouter with the poet's tools, carries out each tool call itself, and
  hands the result back, until the model answers without a tool call.

  What OpenClaw does for a sprite poet, done here:

    * **Tool calls.** Several per reply are run in order. Arguments that are
      not JSON are answered with an error the model can act on ("resend it as
      JSON") instead of failing the run; each is counted as malformed.
    * **Policy.** Every call passes `policy/3` first, the one place that
      decides whether a tool may run (the Temporal Agent Harness's idea:
      allow, deny, later hold for approval). Today it denies tools that are
      not offered, and in shadow mode sends every write to `AppLoop.Draft`.
    * **Context.** Each run starts fresh: the system prompt (the poet's
      workspace files) and the day's trigger, nothing carried over from
      earlier days. That is the difference the shadow run measures against a
      sprite's one long session.
    * **Limits.** At most `:max_model_calls` replies (default 60) and a
      deadline (default 15 minutes); one result is capped so a long page
      cannot crowd the run out.

  The run's inputs are a map: `user` and `poet` (whose endpoints the reads
  go to), `model`, `system`, `trigger`, `entry_date`, `context` (a frozen
  `get_poet_context` answer, as text, or nil to read the live one), `files`
  (workspace path => content, for the `read` tool) and `day` (travel.day).
  """

  require Logger

  alias TravelingPoet.AppLoop.{Dispatch, Draft, Tools, Web}

  @api_url "https://openrouter.ai/api/v1/chat/completions"
  @result_cap 30_000

  @doc """
  Runs one day. Returns a summary map: `status` ("published", "unpublished",
  "error", "limit"), the `draft`, `steps` (one per tool call), counts,
  tokens, cost and duration.
  """
  def run(inputs, opts \\ []) do
    shadow? = Keyword.get(opts, :shadow, true)

    state = %{
      inputs: inputs,
      opts: opts,
      shadow?: shadow?,
      draft: Draft.new(inputs.entry_date, inputs[:day]),
      messages: [
        %{role: "system", content: inputs.system},
        %{role: "user", content: inputs.trigger}
      ],
      steps: [],
      model_calls: 0,
      malformed: 0,
      tokens_in: 0,
      tokens_out: 0,
      cost: 0.0,
      final_text: nil,
      started: System.monotonic_time(:millisecond),
      deadline: System.monotonic_time(:millisecond) + Keyword.get(opts, :deadline_ms, 900_000)
    }

    state |> loop() |> summary()
  end

  defp loop(state) do
    cond do
      state.model_calls >= Keyword.get(state.opts, :max_model_calls, 60) ->
        Map.put(state, :stop, {"limit", "too many model calls"})

      System.monotonic_time(:millisecond) > state.deadline ->
        Map.put(state, :stop, {"limit", "deadline passed"})

      true ->
        case chat(state) do
          {:ok, msg, usage} ->
            state = count_usage(state, usage)
            calls = msg["tool_calls"] || []
            state = %{state | messages: state.messages ++ [assistant_message(msg)]}

            if calls == [] do
              %{state | final_text: msg["content"]}
            else
              calls |> Enum.reduce(state, &run_call/2) |> loop()
            end

          {:error, reason} ->
            Map.put(state, :stop, {"error", reason})
        end
    end
  end

  # What goes back into the conversation: the reply's text, its tool calls,
  # and the reasoning OpenRouter asks to be returned with tool calls.
  defp assistant_message(msg) do
    Map.take(msg, ~w(role content tool_calls reasoning_details))
    |> Map.put_new("role", "assistant")
  end

  defp run_call(call, state) do
    name = get_in(call, ["function", "name"])
    raw = get_in(call, ["function", "arguments"])
    started = System.monotonic_time(:millisecond)

    # The loop's own refusals (bad JSON, no such tool) are said plainly; an
    # endpoint's answer is wrapped as the plugin wraps it.
    {status, reply, state, wrap?} =
      case decode_args(raw) do
        {:ok, args} ->
          case execute(name, args, state) do
            {:loop, status, reply, state} -> {status, reply, state, false}
            {status, reply, state} -> {status, reply, state, true}
          end

        :error ->
          {400,
           %{
             "error" =>
               "Your arguments for #{name} were not valid JSON. Send the call again with the arguments as one JSON object."
           }, %{state | malformed: state.malformed + 1}, false}
      end

    step = %{
      "tool" => name,
      "status" => status,
      "ms" => System.monotonic_time(:millisecond) - started,
      "error" => if(status >= 400, do: reply |> error_text() |> String.slice(0, 300))
    }

    reply = if wrap?, do: wrap(name, status, reply), else: reply
    content = reply |> Jason.encode!() |> cap(name)

    %{
      state
      | steps: state.steps ++ [step],
        messages: state.messages ++ [%{role: "tool", tool_call_id: call["id"], content: content}]
    }
  end

  defp decode_args(nil), do: {:ok, %{}}
  defp decode_args(""), do: {:ok, %{}}
  defp decode_args(args) when is_map(args), do: {:ok, args}

  defp decode_args(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, args} when is_map(args) -> {:ok, args}
      _ -> :error
    end
  end

  defp decode_args(_), do: :error

  defp execute(name, args, state) do
    case policy(name, args, state) do
      :deny ->
        {:loop, 404, %{"error" => "There is no tool called #{name}."}, state}

      :draft ->
        {status, reply, draft} = Draft.apply(state.draft, name, args)
        {status, reply, %{state | draft: draft}}

      :allow ->
        {status, reply} = carry_out(name, args, state)
        {status, reply, state}
    end
  end

  @doc """
  The one gate every tool call passes: `:allow` (carry it out), `:draft`
  (shadow mode: keep the write in the draft) or `:deny`.
  """
  def policy(name, _args, state) do
    case Tools.kind(name) do
      :unknown -> :deny
      :write -> if state.shadow?, do: :draft, else: :allow
      _read_or_builtin -> :allow
    end
  end

  defp carry_out("get_poet_context", _args, %{inputs: %{context: context}})
       when is_binary(context),
       do: {200, decode_or_text(context)}

  defp carry_out("journal_get_entry", args, %{shadow?: true} = state)
       when is_map_key(args, "entry_date") do
    if to_string(args["entry_date"]) == state.draft.entry_date do
      case Draft.entry_view(state.draft) do
        nil -> {404, %{"error" => "no entry for #{state.draft.entry_date}"}}
        view -> {200, view}
      end
    else
      dispatch("journal_get_entry", args, state)
    end
  end

  defp carry_out("web_search", args, state) do
    case Web.search(args["query"], Keyword.take(state.opts, [:api_key])) do
      {:ok, res} -> {200, %{"answer" => res.answer, "citations" => res.citations}}
      {:error, reason} -> {502, %{"error" => to_string(reason)}}
    end
  end

  defp carry_out("web_fetch", args, _state) do
    max = args["maxChars"] || args["max_chars"]
    opts = if is_number(max), do: [max_chars: trunc(min(max, 30_000))], else: []

    case Web.fetch(args["url"], opts) do
      {:ok, page} -> {200, Map.new(page, fn {k, v} -> {to_string(k), v} end)}
      {:error, reason} -> {502, %{"error" => to_string(reason), "url" => args["url"]}}
    end
  end

  defp carry_out("read", %{"path" => path}, state) when is_binary(path) do
    files = state.inputs[:files] || %{}
    key = path |> String.trim_leading("./") |> String.replace(~r{^.*?/workspace/}, "")

    case Map.fetch(files, key) do
      {:ok, text} -> {200, %{"path" => key, "content" => text}}
      :error -> {404, %{"error" => "no such file: #{path}", "files" => Map.keys(files)}}
    end
  end

  defp carry_out("read", _args, _state), do: {422, %{"error" => "path is required"}}

  defp carry_out(name, args, state), do: dispatch(name, args, state)

  defp dispatch(name, args, state) do
    case Tools.route(name, args) do
      nil ->
        {404, %{"error" => "There is no tool called #{name}."}}

      {method, path, body} ->
        {:ok, status, reply} =
          Dispatch.call(state.inputs.user, method, path, body, shadow: state.shadow?)

        {status, reply}
    end
  end

  # A frozen context is what the sprite's tool returned, already wrapped by
  # the plugin; unwrap it so it is wrapped once, like every other reply.
  defp decode_or_text(text) do
    case Jason.decode(text) do
      {:ok, %{"result" => data}} -> data
      {:ok, data} -> data
      _ -> %{"context" => text}
    end
  end

  # The plugin's `call()` shape, so a poet sees what it sees on a sprite:
  # `{result: ...}` on success, `{error: "HTTP 422", details: ...}` on a
  # refusal. OpenClaw's own tools (search, fetch, read) answer as they are.
  defp wrap(name, status, reply) do
    cond do
      Tools.kind(name) not in [:read, :write] -> reply
      status in 200..299 -> %{"result" => reply}
      true -> %{"error" => "HTTP #{status}", "details" => reply}
    end
  end

  defp error_text(%{"error" => e}) when is_binary(e), do: e
  defp error_text(reply), do: inspect(reply)

  # The context is whole (it is the day); anything else is capped.
  defp cap(content, "get_poet_context"), do: content

  defp cap(content, _name) do
    if String.length(content) > @result_cap,
      do: String.slice(content, 0, @result_cap) <> "…[cut]",
      else: content
  end

  defp count_usage(state, usage) do
    %{
      state
      | model_calls: state.model_calls + 1,
        tokens_in: state.tokens_in + (usage["prompt_tokens"] || 0),
        tokens_out: state.tokens_out + (usage["completion_tokens"] || 0),
        cost: state.cost + (usage["cost"] || 0)
    }
  end

  defp chat(state) do
    key =
      Keyword.get(state.opts, :api_key, Application.get_env(:traveling_poet, :openrouter_api_key))

    if key in [nil, ""] do
      {:error, "OpenRouter is not configured"}
    else
      body = %{
        model: state.inputs.model,
        messages: state.messages,
        tools: Tools.definitions(),
        tool_choice: "auto",
        # What poets get in production (Provisioner's openclaw.json).
        max_tokens: 32_768,
        usage: %{include: true}
      }

      case Req.post(
             @api_url,
             [
               json: body,
               headers: [{"authorization", "Bearer #{key}"}],
               receive_timeout: 400_000,
               retry: :transient
             ] ++ Application.get_env(:traveling_poet, :app_loop_req_options, [])
           ) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => msg} | _]} = b}} ->
          {:ok, msg, b["usage"] || %{}}

        {:ok, %{status: 200, body: %{"error" => error}}} ->
          {:error, "model error: #{inspect(error) |> String.slice(0, 300)}"}

        {:ok, %{status: status, body: b}} ->
          {:error, "#{status}: #{b |> inspect() |> String.slice(0, 300)}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp summary(state) do
    published? = Draft.published?(state.draft)

    {status, error} =
      case state[:stop] do
        nil -> {if(published?, do: "published", else: "unpublished"), nil}
        {_kind, reason} when published? -> {"published", reason}
        {kind, reason} -> {kind, reason}
      end

    %{
      status: status,
      error: error,
      draft: state.draft,
      steps: state.steps,
      model_calls: state.model_calls,
      tool_calls: length(state.steps),
      malformed_calls: state.malformed,
      tool_errors: Enum.count(state.steps, &(&1["status"] >= 400)),
      tokens_in: state.tokens_in,
      tokens_out: state.tokens_out,
      cost: state.cost,
      ms: System.monotonic_time(:millisecond) - state.started,
      final_text: state.final_text
    }
  end
end
