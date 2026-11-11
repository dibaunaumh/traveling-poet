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

  alias TravelingPoet.{Journal, Poets}
  alias TravelingPoet.Journal.PageFacts

  @source "traveling-poet"
  # The links that say which notification brought the reader (`?via=`).
  @via_channels ~w(email telegram push)
  # A page changed this long after publishing is reported again; an older one
  # has no leaf left to refresh.
  @refresh_hours 48

  # -- identities --------------------------------------------------------

  def poet_party(nil), do: nil

  def poet_party(%{id: id, name: name}),
    do: AliceInContext.party(:agent, "poet-#{id}", source: @source, name: name)

  def poet_party(%{id: id}), do: AliceInContext.party(:agent, "poet-#{id}", source: @source)

  # A reader is a user, or just its id; the display name rides along when the user has one, so the
  # forest's birds and the feed can say who read a page (names only, never member text — ADR 0004).
  def reader_party(%{id: id} = user),
    do: AliceInContext.party(:human, "user-#{id}", source: @source, name: display_name(user))

  def reader_party(user_id), do: AliceInContext.party(:human, "user-#{user_id}", source: @source)

  defp display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(_), do: nil
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
        metadata:
          compact(%{
            tool: name,
            phase: phase,
            call_id: data["toolCallId"] || data["id"],
            channel: "sprite",
            args: scalar_args(data["args"] || data["input"])
          }),
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

  @doc """
  A page was published, or what it holds changed afterwards. The page's facts
  ride along (`Journal.PageFacts`): its parts with their sizes and what it
  lacks. The id carries a digest of those facts, so the same page reported
  twice is one event, and a page that gained its places or its drawing after
  publishing is a new one that corrects the first.
  """
  def journal_published(entry) do
    poet = poet_party(%{id: entry.poet_id})
    page = PageFacts.of(entry)

    emit(%{
      id: "evt_published_entry-#{entry.id}_#{page_digest(page)}",
      type: "task",
      verb: "journal_published",
      actor: poet,
      subjects: [%{kind: "entry", id: to_string(entry.id)}],
      refs: entry_refs(entry),
      hints: %{space: "organization", address: "Serve/shared/Journal/#{poet.id}/entries"},
      body: entry_title(entry),
      privacy: "public",
      metadata: %{page: page}
    })
  rescue
    e ->
      Logger.debug("AiC journal_published failed: #{inspect(e)}")
      :error
  end

  @doc """
  The poet changed a page through the agent API (sections, places, finds,
  stay areas). Places and the drawing usually arrive after the publish call,
  so the page is reported again with what it holds now.
  """
  def page_changed(user_id, date) do
    with {:ok, date} <- Date.from_iso8601(to_string(date)),
         %{} = poet <- Poets.get_poet_by_user(user_id),
         %{} = entry <- Journal.get_entry(poet.id, date),
         true <- fresh?(entry) do
      journal_published(entry)
    else
      _ -> :skipped
    end
  rescue
    e ->
      Logger.debug("AiC page_changed failed: #{inspect(e)}")
      :error
  end

  @doc "Whether an entry was published recently enough to be reported again."
  def fresh?(%{status: "published", published_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at, :hour) < @refresh_hours

  def fresh?(_entry), do: false

  @doc """
  A reader opened a journal entry page: the live mount of `/journal/:date` by the
  owner (channel "owner") or of `/p/:slug/:date` by a signed-in reader ("public").
  The id is fixed per reader, entry and UTC day, so reloads collapse into one read
  on the server. Anonymous visits are never reported (crawlers among them).

  `via` names the notification whose link brought the reader (`?via=email`): the
  only sign that a notification was opened, since nothing in a mail or a push is
  tracked. It is a second read with its own id.
  """
  def entry_read(user, entry, channel, via \\ nil) do
    poet = poet_party(%{id: entry.poet_id})
    reader = reader_party(user)
    via = if via in @via_channels, do: via

    emit(%{
      id:
        "evt_read_#{reader.id}_entry-#{entry.id}_#{Date.utc_today()}" <>
          if(via, do: "_via-#{via}", else: ""),
      type: "activity",
      verb: "read",
      actor: reader,
      recipient: poet,
      subjects: [%{kind: "entry", id: to_string(entry.id)}],
      refs: entry_refs(entry),
      hints: %{space: "organization", address: "Serve/shared/Journal/#{poet.id}/entries"},
      body: entry_title(entry),
      privacy: "internal",
      metadata: compact(%{channel: channel, via: via})
    })
  end

  @doc "The channels a notification link may name, and a link with its channel on it."
  def via_channels, do: @via_channels

  def via(url, channel) when channel in @via_channels do
    {base, fragment} =
      case String.split(url, "#", parts: 2) do
        [base, fragment] -> {base, "#" <> fragment}
        [base] -> {base, ""}
      end

    base <> if(String.contains?(base, "?"), do: "&", else: "?") <> "via=" <> channel <> fragment
  end

  @doc """
  Time the owner spent on one part of their page (`Journal.PageFacts` ids),
  in seconds. Only ever sent for an owner who left reading signals on
  (`TravelingPoet.Reading`); a public reader is never measured. Sent in
  batches by `TravelingPoet.AiC.ReadTally`, and the times add up on the server.
  """
  def part_read(user, entry, part, seconds) do
    poet = poet_party(%{id: entry.poet_id})

    emit(%{
      type: "activity",
      verb: "read",
      actor: reader_party(user),
      recipient: poet,
      subjects: [%{kind: "entry", id: to_string(entry.id)}],
      hints: %{space: "organization", address: "Serve/shared/Journal/#{poet.id}/entries"},
      body: entry_title(entry),
      privacy: "internal",
      metadata: %{channel: "owner", part: part},
      metrics: %{seconds: seconds}
    })
  end

  @doc """
  The owner did something on their page: saved a place, asked for hotels,
  pressed play, followed a link (`action`), on a part of it or on none.
  """
  def interacted(user, entry, action, part \\ nil, extra \\ %{}) do
    poet = poet_party(%{id: entry.poet_id})

    emit(%{
      type: "activity",
      verb: "interact",
      actor: reader_party(user),
      recipient: poet,
      subjects: [%{kind: "entry", id: to_string(entry.id)}],
      hints: %{space: "organization", address: "Serve/shared/Journal/#{poet.id}/entries"},
      body: action,
      privacy: "internal",
      metadata: compact(Map.merge(extra, %{action: action, part: part}))
    })
  end

  @doc "A published entry reached its reader over a channel (email, telegram, push). The page goes out in the poet's name."
  def delivered(user, entry, channel), do: delivery(user, entry, channel, "sent", nil)

  @doc "The channel was tried and refused the page. `reason` may be any term: only a short safe label of it is sent."
  def delivery_failed(user, entry, channel, reason),
    do: delivery(user, entry, channel, "failed", reason_text(reason))

  @doc "The page was not sent over a channel the reader has, and why (\"turned off\")."
  def delivery_skipped(user, entry, channel, reason),
    do: delivery(user, entry, channel, "skipped", reason)

  defp delivery(user, entry, channel, status, reason) do
    poet = poet_party(%{id: entry.poet_id})

    emit(%{
      type: if(status == "failed", do: "error", else: "activity"),
      verb: "deliver",
      actor: poet,
      recipient: reader_party(user),
      subjects: [%{kind: "entry", id: to_string(entry.id)}],
      refs: entry_refs(entry),
      hints: %{space: "organization", address: "Serve/shared/Journal/#{poet.id}/entries"},
      body: entry_title(entry),
      privacy: "internal",
      metadata: compact(%{channel: channel, status: status, reason: reason})
    })
  end

  # What went wrong, in a word or two. Never the term itself: a failed request
  # can carry a URL with a bot token in it.
  defp reason_text({:error, reason}), do: reason_text(reason)
  defp reason_text({:http, status}) when is_integer(status), do: "http #{status}"
  defp reason_text({status, _body}) when is_integer(status), do: "http #{status}"
  defp reason_text(%{reason: reason}) when is_atom(reason), do: to_string(reason)
  defp reason_text(reason) when is_atom(reason), do: to_string(reason)
  defp reason_text(reason) when is_binary(reason), do: String.slice(reason, 0, 60)
  defp reason_text(_), do: "error"

  @praise_markers ~w(interesting beautiful)
  @complaint_markers ~w(boring not_creative meh inaccurate made_up)

  @doc """
  A marker the reader dropped on a passage or a drawing. The kind says whether
  it is praise or a complaint; the requests in between (more details, a link)
  name no sentiment.
  """
  def marker_added(user_id, entry_id, attrs) do
    kind = attr(attrs, :kind)

    emit(%{
      type: "feedback",
      verb: "marker",
      actor: reader_party(user_id),
      recipient: poet_of(user_id),
      subjects: [%{kind: "entry", id: to_string(entry_id)}],
      body: attr(attrs, :note) || attr(attrs, :quote),
      privacy: "human_authored",
      metadata:
        compact(%{
          kind: kind,
          sentiment:
            cond do
              kind in @praise_markers -> "positive"
              kind in @complaint_markers -> "negative"
              true -> nil
            end,
          part:
            if(attr(attrs, :target) == "illustration",
              do: "drawing",
              else: PageFacts.part_of(attr(attrs, :section_kind))
            )
        })
    })
  end

  @doc "One of the reaction buttons under the owner's page (love, inspiring, want more, not for me)."
  def reaction(user, entry, kind) do
    emit(%{
      type: "feedback",
      verb: "reaction",
      actor: reader_party(user),
      recipient: poet_party(%{id: entry.poet_id}),
      subjects: [%{kind: "entry", id: to_string(entry.id)}],
      privacy: "internal",
      metadata: %{
        kind: kind,
        sentiment: if(kind == "not_for_me", do: "negative", else: "positive")
      }
    })
  end

  @doc """
  A note to the team from the feedback form. `kind` "broken" or "missing" is a
  complaint; written from a journal page (`page`), it is about that entry.
  """
  def feedback_message(user_id, text, opts \\ []) do
    kind = opts[:kind]

    emit(%{
      type: "feedback",
      verb: "feedback",
      actor: reader_party(user_id),
      recipient: poet_of(user_id),
      subjects: page_subject(user_id, opts[:page]),
      body: text,
      privacy: "human_authored",
      metadata: compact(%{kind: kind, sentiment: if(kind in ~w(broken missing), do: "negative")})
    })
  end

  def nps(user_id, score, entry_id \\ nil) do
    emit(%{
      type: "feedback",
      verb: "nps",
      actor: reader_party(user_id),
      recipient: poet_of(user_id),
      subjects: entry_id && [%{kind: "entry", id: to_string(entry_id)}],
      metrics: %{score: score},
      privacy: "internal"
    })
  end

  def poet_asked(poet, question) do
    emit(%{
      type: "message",
      verb: "ask",
      actor: poet_party(poet),
      recipient: reader_party(poet.user_id),
      body: preview(question, 500),
      privacy: "internal"
    })
  end

  def illustration(user_id, model, result) do
    poet = poet_of(user_id)

    case result do
      {:ok, %{cost: cost, ms: ms}} ->
        emit(%{
          type: "activity",
          verb: "generate_drawing",
          actor: poet,
          recipient: service_party("illustrations"),
          subjects: [%{kind: "model", id: to_string(model), source: "openrouter"}],
          metrics: %{} |> put_metric("cost_usd", cost) |> put_metric("duration_ms", ms),
          privacy: "internal"
        })

      {:error, reason} ->
        emit(%{
          type: "error",
          verb: "generate_drawing",
          actor: poet,
          recipient: service_party("illustrations"),
          subjects: [%{kind: "model", id: to_string(model), source: "openrouter"}],
          body: "illustration failed: #{inspect(reason) |> String.slice(0, 200)}",
          privacy: "internal"
        })
    end
  end

  @doc "An agent-originated call to the app's /api/agent routes."
  def api_call(user_id, controller, action, status) do
    emit(%{
      type: if(status >= 400, do: "error", else: "activity"),
      verb: "api_#{action}",
      actor: poet_of(user_id),
      recipient: service_party("api:#{controller}"),
      hints: %{
        space: "organization",
        address: "Operate/inner/Services/api/#{controller}/#{action}"
      },
      metadata: %{status: status},
      privacy: "internal"
    })
  end

  @doc """
  How a daily run ended, told by what reached the reader rather than by what
  the turn said: an error when nothing was published, whatever the agent
  replied. Options: `published` (default: the turn ended well), `attempt` (the
  usage row of the attempt, which fixes the event id so a run settled twice is
  one event) and `retry`. `outcome` is `AgentSession.run/3`'s, or
  `:interrupted` for a run whose task died with the deploy.
  """
  def daily_run(user_id, poet, outcome, opts \\ []) do
    published? = Keyword.get(opts, :published, match?({:ok, _}, outcome))
    attempt = opts[:attempt]

    emit(%{
      id: attempt && "evt_daily_run_attempt-#{attempt}",
      type: if(published?, do: "activity", else: "error"),
      verb: "daily_run",
      actor: system_party("scheduler"),
      recipient: poet_party(poet),
      hints: %{
        space: "organization",
        address: "Operate/inner/Fleet/poet-#{poet.id}/travel_n_journal"
      },
      body: outcome_text(outcome, published?),
      privacy: "internal",
      metadata:
        compact(%{user_id: user_id, published: published?, attempt: attempt, retry: opts[:retry]})
    })
  end

  @doc """
  The day's roster: this poet is expected to publish on `date`, at `due_at`,
  or is not (`status` "paused" or "no_credits", with a `reason`). Sent ahead
  of the hour, so a poet that then does nothing can be told from one that was
  never due. A changed status is a new event; the last one of the day stands.
  """
  def expected(poet, %{date: date, due_at: due_at, status: status} = entry) do
    credits = Map.get(entry, :credits)

    emit(%{
      id: "evt_expected_poet-#{poet.id}_#{date}_#{status}_#{credits || "exempt"}",
      type: "activity",
      verb: "expected",
      actor: poet_party(poet),
      hints: %{
        space: "organization",
        address: "Operate/inner/Fleet/poet-#{poet.id}/travel_n_journal"
      },
      body:
        if(status == "due",
          do: "due at #{Calendar.strftime(due_at, "%H:%M")} UTC",
          else: "not due: #{Map.get(entry, :reason) || status}"
        ),
      privacy: "internal",
      metadata:
        compact(%{
          due_at: DateTime.to_iso8601(due_at),
          status: status,
          reason: Map.get(entry, :reason)
        }),
      metrics: put_metric(%{}, "credits", credits)
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

  defp compact(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  # The arguments of a tool call that say what it was about (the query, the
  # url, the date), as short scalars: the forest prints one on the leaf.
  defp scalar_args(args) when is_map(args) do
    args
    |> Enum.filter(fn {_k, v} -> is_binary(v) or is_number(v) or is_boolean(v) end)
    |> Enum.take(8)
    |> Map.new(fn
      {k, v} when is_binary(v) -> {to_string(k), String.slice(v, 0, 160)}
      {k, v} -> {to_string(k), v}
    end)
    |> case do
      empty when empty == %{} -> nil
      scalars -> scalars
    end
  end

  defp scalar_args(_), do: nil

  # Parts and their item counts, and what is missing. Word counts are left
  # out: a revised sentence is not a new fact about the page.
  defp page_digest(page) do
    facts = {Enum.map(page.parts, &{&1.id, Map.get(&1, :count)}), page.missing}

    :crypto.hash(:sha256, inspect(facts))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  # The entry a feedback note was written on, when its page is a journal date.
  defp page_subject(user_id, page) when is_binary(page) do
    with [_, date] <- Regex.run(~r|/journal/(\d{4}-\d{2}-\d{2})|, page),
         {:ok, date} <- Date.from_iso8601(date),
         %{} = poet <- Poets.get_poet_by_user(user_id),
         %{id: id} <- Journal.get_entry(poet.id, date) do
      [%{kind: "entry", id: to_string(id)}]
    else
      _ -> nil
    end
  end

  defp page_subject(_user_id, _page), do: nil

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
    base =
      Application.get_env(:traveling_poet, :public_base_url) || TravelingPoetWeb.Endpoint.url()

    date = Map.get(entry, :date) || Map.get(entry, :entry_date)

    case Poets.get_poet!(entry.poet_id) do
      %{slug: slug} when is_binary(slug) and not is_nil(date) ->
        [
          %{
            system: @source,
            kind: "entry",
            id: to_string(entry.id),
            url: "#{base}/p/#{slug}/#{date}"
          }
        ]

      _ ->
        [%{system: @source, kind: "entry", id: to_string(entry.id)}]
    end
  rescue
    _ -> [%{system: @source, kind: "entry", id: to_string(entry.id)}]
  end

  defp entry_title(entry), do: Map.get(entry, :title) || "Journal entry #{Map.get(entry, :date)}"

  defp outcome_text({:ok, _}, true), do: "published"
  defp outcome_text({:timeout, _}, true), do: "published, then the turn stalled"
  defp outcome_text({:error, _}, true), do: "published, then the turn failed"
  defp outcome_text(:interrupted, true), do: "published; the run was interrupted"
  defp outcome_text({:ok, _}, false), do: "failed: finished its turn without publishing"
  defp outcome_text({:timeout, _}, false), do: "timed out with nothing published"
  defp outcome_text(:interrupted, false), do: "failed: interrupted with nothing published"

  defp outcome_text({:error, reason}, false),
    do: "failed: #{inspect(reason) |> String.slice(0, 200)}"

  defp outcome_text(other, _published?), do: inspect(other) |> String.slice(0, 200)
end
