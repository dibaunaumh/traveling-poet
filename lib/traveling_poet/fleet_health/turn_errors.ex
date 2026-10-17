defmodule TravelingPoet.FleetHealth.TurnErrors do
  @moduledoc """
  Pages the admins the moment a poet's turn fails, with the cause.

  The gateway tells the app about every failed turn as it happens (an
  `agent` lifecycle error or a chat `error` state on the socket), but until
  2026-10-16 that only became "Agent error" in the reader's chat and a line
  in the app log. Udi's poet failed every chat turn for an evening before
  anyone looked, and the reason, OpenRouter's "404 No endpoints found that
  support image input", was only in the gateway log on the sprite. The
  friendly message the gateway sends ("The AI service couldn't accept this
  request") does not name it.

  So: on each failed turn, record a `turn_error` usage event (the admin
  page and the fleet health check can count them), and page the admins
  once per poet per `@quiet_hours`, with what the poet was doing (from the
  attempt events of the last minutes), the gateway's message, and the last
  provider error from the sprite's gateway log, read while the sprite is
  still awake from the turn. Polling every sprite's log on a schedule was
  the alternative, and it would wake and bill each sprite every time.

  Only a reader's chat pages (Udi, 2026-10-17: "only page for chat
  failures"). A scheduled turn (daily run, first entry, marker revision,
  book) is counted and nothing more: the scheduler retries it, and the
  fleet health check pages when a poet stops publishing. The first morning
  of paging, two daily runs failed on the model's "incomplete or malformed
  tool call", paged, and published on the next attempt.

  `report_async/2` is what the socket calls; `report/3` does the work and
  takes `:notify` and `:raw` functions so tests need no Telegram and no
  sprite.
  """

  import Ecto.Query

  require Logger

  alias TravelingPoet.{Accounts, Alerts, Poets, Repo, SpritesClient, Usage}
  alias TravelingPoet.Usage.UsageEvent

  @quiet_hours 4
  @echo_seconds 10
  @context_minutes 15
  @context_kinds %{
    "daily_run_attempt" => "daily run",
    "first_entry_attempt" => "first entry",
    "marker_revision_attempt" => "marker revision",
    "book_compose_attempt" => "book"
  }

  @doc "Records and pages in a task of its own; the socket never waits."
  def report_async(user_id, message) do
    Task.start(fn -> report(user_id, message) end)
  end

  @doc """
  Records the failed turn and pages the admins unless they were paged about
  this poet in the last #{@quiet_hours} hours. Returns `{:ok, :paged}`,
  `{:ok, :quiet}`, `{:ok, :recorded}` for a scheduled turn, `{:ok, :echo}`
  for another error event of a turn recorded in the last #{@echo_seconds}
  seconds, or `{:error, reason}` from the page.
  """
  def report(user_id, message, opts \\ []) do
    notify = Keyword.get(opts, :notify, &Alerts.notify_admins/1)
    raw = Keyword.get(opts, :raw, &gateway_error/1)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    message = message |> to_string() |> String.slice(0, 300)
    channel = channel_for(user_id, now)

    # One failed turn reaches the socket as three error events within the
    # same second (the agent lifecycle error, the chat error state and the
    # error-shaped event), each reported in a task of its own. On 2026-10-17
    # all three read the quiet window before any had recorded the page, and
    # the admins got three pages per poet; the admin page then showed "3 turn
    # errors" for one failed turn all day. Record and page under a lock per
    # poet, and let a report within `@echo_seconds` of the last be that same
    # turn: the second and third find the first one's record and add nothing.
    :global.trans({{__MODULE__, user_id}, self()}, fn ->
      cond do
        recorded_recently?(user_id, now) ->
          {:ok, :echo}

        true ->
          {:ok, _} =
            Usage.record(user_id, "turn_error", %{
              occurred_at: DateTime.truncate(now, :second),
              metadata: %{"message" => message, "channel" => channel}
            })

          if channel == "chat" do
            page_unless_quiet(user_id, channel, message, now, notify, raw)
          else
            {:ok, :recorded}
          end
      end
    end)
  end

  @doc """
  How many of the reader's own chat turns failed today. The admin page shows
  this, not every turn error: a scheduled turn's failure is retried and shows
  as a missed or late day if the retries fail too, so a poet that published
  after one bad attempt has nothing to report. The four poets flagged on the
  admin page's first evening (2026-10-17) had all published.
  """
  def chat_failures_today(user_id, now \\ DateTime.utc_now()) do
    start = now |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    UsageEvent
    |> where([e], e.user_id == ^user_id and e.kind == "turn_error" and e.occurred_at >= ^start)
    |> where([e], fragment("json_extract(?, '$.channel')", e.metadata) == "chat")
    |> select([e], count(e.id))
    |> Repo.one()
  end

  defp page_unless_quiet(user_id, channel, message, now, notify, raw) do
    if paged_recently?(user_id, now) do
      {:ok, :quiet}
    else
      user = Accounts.get_user(user_id)
      poet = Poets.get_poet_by_user(user_id)
      cause = user && raw.(user)

      case notify.(text(user, poet, channel, message, cause)) do
        :ok ->
          {:ok, _} = Usage.record(user_id, "turn_error_alert")
          {:ok, :paged}

        {:error, reason} = err ->
          Logger.warning("TurnErrors: could not page about user #{user_id}: #{inspect(reason)}")
          err
      end
    end
  end

  @doc "What the admins read."
  def text(user, poet, channel, message, cause) do
    who =
      case {poet, user} do
        {%{name: name}, %{email: email}} when is_binary(name) -> "#{name} (#{email})"
        {_, %{email: email}} -> email
        _ -> "unknown poet"
      end

    [
      "Poet turn failed: #{who}, during #{channel}.",
      "Gateway said: #{message}",
      cause && "Provider error: #{cause}",
      "Repeats are quiet for #{@quiet_hours} h. #{Alerts.admin_url()}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # The attempt events say what the app had the poet doing; a turn with
  # none behind it is a reader's chat (web or Telegram) or a guide request.
  defp channel_for(user_id, now) do
    since = DateTime.add(now, -@context_minutes, :minute)
    kinds = Map.keys(@context_kinds)

    UsageEvent
    |> where([e], e.user_id == ^user_id and e.kind in ^kinds and e.occurred_at >= ^since)
    |> order_by(desc: :occurred_at)
    |> limit(1)
    |> select([e], e.kind)
    |> Repo.one()
    |> case do
      nil -> "chat"
      kind -> Map.fetch!(@context_kinds, kind)
    end
  end

  defp recorded_recently?(user_id, now) do
    since = DateTime.add(now, -@echo_seconds, :second)

    UsageEvent
    |> where([e], e.user_id == ^user_id and e.kind == "turn_error" and e.occurred_at >= ^since)
    |> Repo.exists?()
  end

  defp paged_recently?(user_id, now) do
    since = DateTime.add(now, -@quiet_hours, :hour)

    UsageEvent
    |> where(
      [e],
      e.user_id == ^user_id and e.kind == "turn_error_alert" and e.occurred_at >= ^since
    )
    |> Repo.exists?()
  end

  # The last provider error the gateway logged today: the line the friendly
  # message hides. The sprite is awake, it just answered the turn.
  @doc false
  def gateway_error(%{sprite_name: name}) when is_binary(name) do
    cmd =
      "grep -h -o 'rawErrorPreview\":\"[^\"]*' /tmp/openclaw/openclaw-$(date -u +%F).log 2>/dev/null | tail -1"

    case client().exec(name, cmd) do
      {:ok, out} ->
        out
        |> extract_text()
        |> String.replace(~s(rawErrorPreview":"), "")
        |> String.trim()
        |> case do
          "" -> nil
          cause -> String.slice(cause, 0, 300)
        end

      _ ->
        nil
    end
  end

  def gateway_error(_), do: nil

  defp client, do: Application.get_env(:traveling_poet, :sprites_client, SpritesClient)

  defp extract_text(data) when is_binary(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.filter(fn b -> b >= 32 or b == 10 end)
    |> List.to_string()
  end

  defp extract_text(other), do: to_string(other)
end
