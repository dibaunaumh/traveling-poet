defmodule TravelingPoet.AiC do
  @moduledoc """
  The Alice-in-Context tap: turns what happens in the app into AiC events
  (spec: alice-in-context/docs/spec/SPEC-ADDITIONS.md). Every function here
  is fire-and-forget; `AliceInContext.emit/1` returns at once and the outbox
  batches, signs and retries. Nothing in the app waits on AiC.

  Identities: a poet is `agent:poet-<poet id>`, a reader is `human:user-<user id>`
  (never the email), app services are `service:<name>`, the scheduler and
  other drivers are `system:<name>`. Reader text is always `human_authored`,
  so AiC keeps a summary and drops the body unless this source opted in.
  """

  require Logger

  alias TravelingPoet.Poets

  @source "traveling-poet"

  # -- identities --------------------------------------------------------

  def poet_party(nil), do: nil

  def poet_party(%{id: id, name: name}),
    do: AliceInContext.party(:agent, "poet-#{id}", source: @source, name: name)

  def poet_party(%{id: id}), do: AliceInContext.party(:agent, "poet-#{id}", source: @source)

  def reader_party(user_id), do: AliceInContext.party(:human, "user-#{user_id}", source: @source)
  def service_party(name), do: AliceInContext.party(:service, name, source: @source)
  def system_party(name), do: AliceInContext.party(:system, name, source: @source)

  @doc "The poet of a user, as a party, or nil."
  def poet_of(user_id) do
    case Poets.get_poet_by_user(user_id) do
      nil -> nil
      poet -> poet_party(poet)
    end
  rescue
    _ -> nil
  end

  # -- events ------------------------------------------------------------

  @doc "A tool event frame from the OpenClaw gateway (`stream: \"tool\"`)."
  def tool_event(user_id, data) when is_map(data) do
    with %{} = poet <- poet_of(user_id) do
      name = data["name"] || data["tool"] || data["toolName"] || "tool"
      phase = data["phase"] || data["status"] || "call"

      emit(%{
        type: if(phase in ["error", "failed"], do: "error", else: "activity"),
        verb: "tool_#{phase}",
        actor: poet,
        recipient: service_party("tool:#{name}"),
        subjects: [%{kind: "tool", id: to_string(name)}],
        hints: %{space: "organization", address: "Operate/inner/Fleet/#{poet.id}/#{name}"},
        body: preview(data["args"] || data["input"] || data["result"] || data["output"]),
        privacy: "internal",
        metadata: %{tool: name, phase: phase, call_id: data["toolCallId"] || data["id"], channel: "sprite"},
        metrics: Map.take(data, ["durationMs", "duration_ms"]) |> normalize_metrics()
      })
    end
  end

  @doc "Start/end of an agent turn seen on the gateway (lifecycle frames)."
  def turn_phase(user_id, phase) do
    with %{} = poet <- poet_of(user_id) do
      emit(%{
        type: "activity",
        verb: "turn_#{phase}",
        actor: poet,
        hints: %{space: "organization", address: "Operate/inner/Fleet/#{poet.id}/turns"},
        privacy: "internal"
      })
    end
  end

  @doc "A usage ledger row became an AiC metric (or an error for turn errors)."
  def usage(user_id, kind, attrs) do
    poet = poet_of(user_id) || reader_party(user_id)
    meta = Map.get(attrs, :metadata) || %{}

    base = %{
      actor: poet,
      hints: %{space: "organization", address: "Operate/inner/Fleet/#{poet.id}/#{kind}"},
      metrics:
        %{}
        |> put_metric("tokens_in", Map.get(attrs, :tokens_in))
        |> put_metric("tokens_out", Map.get(attrs, :tokens_out))
        |> put_metric("cost_cents_est", Map.get(attrs, :cost_cents_est)),
      metadata: Map.put(stringify(meta), "kind", kind),
      privacy: "internal"
    }

    case kind do
      "turn_error" <> _ ->
        emit(Map.merge(base, %{type: "error", verb: kind, body: meta["message"]}))

      _ ->
        emit(Map.merge(base, %{type: "metric", verb: kind}))
    end
  end

  @doc "The app sent the poet a message on the reader's behalf or its own (AgentSession.run)."
  def turn_requested(user, channel, message) do
    poet = poet_of(user.id)
    human? = channel in ["web", "telegram"]

    emit(%{
      type: if(human?, do: "message", else: "activity"),
      verb: if(human?, do: "chat", else: "trigger"),
      actor: if(human?, do: reader_party(user.id), else: system_party(channel)),
      recipient: poet,
      body: if(human?, do: message, else: preview(message)),
      privacy: if(human?, do: "human_authored", else: "internal"),
      metadata: %{channel: channel}
    })
  end

  @doc "A poet's reply was saved (Chat.create_message with role agent)."
  def poet_replied(user_id, content, channel) do
    emit(%{
      type: "message",
      verb: "reply",
      actor: poet_of(user_id),
      recipient: reader_party(user_id),
      body: preview(content, 500),
      privacy: "internal",
      metadata: %{channel: channel}
    })
  end

  def journal_published(entry) do
    poet = poet_party(%{id: entry.poet_id})

    emit(%{
      type: "task",
      verb: "journal_published",
      actor: poet,
      subjects: [%{kind: "entry", id: to_string(entry.id)}],
      refs: entry_refs(entry),
      hints: %{space: "organization", address: "Serve/shared/Journal/#{poet.id}/entries"},
      body: entry_title(entry),
      privacy: "public"
    })
  end

  def marker_added(user_id, entry_id, attrs) do
    emit(%{
      type: "feedback",
      verb: "marker",
      actor: reader_party(user_id),
      recipient: poet_of(user_id),
      subjects: [%{kind: "entry", id: to_string(entry_id)}],
      body: Map.get(attrs, :note) || Map.get(attrs, "note") || Map.get(attrs, :quote) || Map.get(attrs, "quote"),
      privacy: "human_authored",
      metadata: %{kind: Map.get(attrs, :kind) || Map.get(attrs, "kind")}
    })
  end

  def feedback_message(user_id, text) do
    emit(%{type: "feedback", verb: "feedback", actor: reader_party(user_id), recipient: poet_of(user_id),
           body: text, privacy: "human_authored"})
  end

  def nps(user_id, score) do
    emit(%{type: "feedback", verb: "nps", actor: reader_party(user_id), recipient: poet_of(user_id),
           metrics: %{score: score}, privacy: "internal"})
  end

  def poet_asked(poet, question) do
    emit(%{type: "message", verb: "ask", actor: poet_party(poet), recipient: reader_party(poet.user_id),
           body: preview(question, 500), privacy: "internal"})
  end

  def illustration(user_id, model, result) do
    poet = poet_of(user_id)

    case result do
      {:ok, %{cost: cost, ms: ms}} ->
        emit(%{type: "activity", verb: "generate_drawing", actor: poet, recipient: service_party("illustrations"),
               subjects: [%{kind: "model", id: to_string(model), source: "openrouter"}],
               metrics: %{} |> put_metric("cost_usd", cost) |> put_metric("duration_ms", ms), privacy: "internal"})

      {:error, reason} ->
        emit(%{type: "error", verb: "generate_drawing", actor: poet, recipient: service_party("illustrations"),
               subjects: [%{kind: "model", id: to_string(model), source: "openrouter"}],
               body: "illustration failed: #{inspect(reason) |> String.slice(0, 200)}", privacy: "internal"})
    end
  end

  @doc "An agent-originated call to the app's /api/agent routes."
  def api_call(user_id, controller, action, status) do
    emit(%{
      type: if(status >= 400, do: "error", else: "activity"),
      verb: "api_#{action}",
      actor: poet_of(user_id),
      recipient: service_party("api:#{controller}"),
      hints: %{space: "organization", address: "Operate/inner/Services/api/#{controller}/#{action}"},
      metadata: %{status: status},
      privacy: "internal"
    })
  end

  def daily_run(user_id, poet, outcome) do
    emit(%{
      type: if(match?({:ok, _}, outcome), do: "activity", else: "error"),
      verb: "daily_run",
      actor: system_party("scheduler"),
      recipient: poet_party(poet),
      hints: %{space: "organization", address: "Operate/inner/Fleet/poet-#{poet.id}/travel_n_journal"},
      body: outcome_text(outcome),
      privacy: "internal",
      metadata: %{user_id: user_id}
    })
  end

  # -- helpers -----------------------------------------------------------

  @doc false
  def emit(event) do
    event =
      event
      |> Map.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.update(:subjects, [], &Enum.reject(&1, fn s -> is_nil(s) end))

    if Map.has_key?(event, :actor) do
      AliceInContext.emit(event)
    else
      :skipped
    end
  rescue
    e ->
      Logger.debug("AiC emit failed: #{inspect(e)}")
      :error
  end

  defp preview(nil), do: nil
  defp preview(v, max \\ 2_000)
  defp preview(nil, _max), do: nil
  defp preview(v, max) when is_binary(v), do: String.slice(v, 0, max)
  defp preview(v, max), do: v |> inspect(limit: 50) |> String.slice(0, max)

  defp put_metric(m, _k, nil), do: m
  defp put_metric(m, k, v) when is_number(v), do: Map.put(m, k, v)
  defp put_metric(m, _k, _v), do: m

  defp normalize_metrics(map) do
    Enum.reduce(map, %{}, fn
      {"durationMs", v}, acc when is_number(v) -> Map.put(acc, "duration_ms", v)
      {"duration_ms", v}, acc when is_number(v) -> Map.put(acc, "duration_ms", v)
      _, acc -> acc
    end)
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}

  defp entry_refs(entry) do
    base = Application.get_env(:traveling_poet, :public_base_url) || TravelingPoetWeb.Endpoint.url()
    date = Map.get(entry, :date) || Map.get(entry, :entry_date)

    case Poets.get_poet!(entry.poet_id) do
      %{slug: slug} when is_binary(slug) and not is_nil(date) ->
        [%{system: @source, kind: "entry", id: to_string(entry.id), url: "#{base}/p/#{slug}/#{date}"}]

      _ ->
        [%{system: @source, kind: "entry", id: to_string(entry.id)}]
    end
  rescue
    _ -> [%{system: @source, kind: "entry", id: to_string(entry.id)}]
  end

  defp entry_title(entry), do: Map.get(entry, :title) || "Journal entry #{Map.get(entry, :date)}"

  defp outcome_text({:ok, _}), do: "published"
  defp outcome_text({:timeout, _}), do: "timed out"
  defp outcome_text({:error, reason}), do: "failed: #{inspect(reason) |> String.slice(0, 200)}"
  defp outcome_text(other), do: inspect(other) |> String.slice(0, 200)
end
