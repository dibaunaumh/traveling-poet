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

  `report_async/2` is what the socket calls; `report/3` does the work and
  takes `:notify` and `:raw` functions so tests need no Telegram and no
  sprite.
  """

  import Ecto.Query

  require Logger

  alias TravelingPoet.{Accounts, Alerts, Poets, Repo, SpritesClient, Usage}
  alias TravelingPoet.Usage.UsageEvent

  @quiet_hours 4
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
  `{:ok, :quiet}` or `{:error, reason}` from the page.
  """
  def report(user_id, message, opts \\ []) do
    notify = Keyword.get(opts, :notify, &Alerts.notify_admins/1)
    raw = Keyword.get(opts, :raw, &gateway_error/1)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    message = message |> to_string() |> String.slice(0, 300)
    channel = channel_for(user_id, now)

    {:ok, _} =
      Usage.record(user_id, "turn_error", %{
        metadata: %{"message" => message, "channel" => channel}
      })

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
