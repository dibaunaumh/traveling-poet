defmodule TravelingPoet.Analytics do
  @moduledoc """
  First-party visit counting, so the funnel from landing page to first entry
  is visible without a tracker, a vendor, or a cookie.

  A visitor is `sha256(salt(day) <> ip <> user_agent)`, cut to 16 hex chars.
  The salt is derived from `secret_key_base` and the UTC date, so an id lives
  for one day and cannot be reversed or joined to the next. The Google round
  trip happens on the same IP, browser and day, so a landing visit and the
  sign-up it led to share an id; the `signup`/`login` row also carries the
  user_id, which is the only place an anonymous visit meets an account.

  Page events come from `assets/js/beacon.js` through `POST /e`: a page view is
  counted only when the page's JavaScript ran, which keeps most bots out, and
  `bot?/1` drops the self-declared rest. Raw rows are kept for
  `@retention_days` (`prune/1`, run daily by `Analytics.Server`).
  """

  import Ecto.Query

  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Analytics.VisitEvent
  alias TravelingPoet.Journal.Entry
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.Repo

  require Logger

  @retention_days 180
  @rate_table :tpoet_analytics_rate
  # Events per visitor per minute. A real reader makes a handful.
  @rate_limit 60

  @onboarding_steps ~w(poet journey send_off done)

  def retention_days, do: @retention_days
  def rate_table, do: @rate_table

  ## Identity

  @doc "The day-scoped anonymous id for this request."
  def visitor_id(%Plug.Conn{} = conn, date \\ Date.utc_today()) do
    ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
    visitor_id(client_ip(conn), ua, date)
  end

  def visitor_id(ip, ua, %Date{} = date) when is_binary(ip) and is_binary(ua) do
    :crypto.hash(:sha256, [salt(date), 0, ip, 0, ua])
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp salt(date) do
    base = TravelingPoetWeb.Endpoint.config(:secret_key_base) || ""
    :crypto.mac(:hmac, :sha256, base, "visit-salt:" <> Date.to_iso8601(date))
  end

  @doc "The visitor's IP: Fly's proxy header when present, else the socket peer."
  def client_ip(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "fly-client-ip") do
      [ip | _] when ip != "" -> ip
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  @bot_ua ~r/bot|crawl|spider|slurp|preview|headless|lighthouse|pingdom|uptime|monitor|curl|wget|python|go-http|java\/|facebookexternalhit|embedly|whatsapp|telegram/i

  @doc "Self-declared robots and link unfurlers (and an empty user agent)."
  def bot?(ua) when is_binary(ua), do: ua == "" or Regex.match?(@bot_ua, ua)
  def bot?(_), do: true

  ## Writing

  @doc """
  Stores one event. Best effort: invalid input, a rate-limited visitor, or a
  database error returns `:dropped` and never raises, because counting must
  never break the page or the sign-in it rides on.
  """
  def record(attrs) do
    with true <- allow?(attrs[:visitor] || attrs["visitor"]),
         {:ok, _} <- %VisitEvent{} |> VisitEvent.changeset(attrs) |> Repo.insert() do
      :ok
    else
      _ -> :dropped
    end
  rescue
    e ->
      Logger.warning("analytics: dropped event: #{Exception.message(e)}")
      :dropped
  end

  defp allow?(visitor) when is_binary(visitor) do
    case :ets.whereis(@rate_table) do
      :undefined ->
        true

      _ ->
        minute = System.system_time(:second) |> div(60)

        :ets.update_counter(@rate_table, {visitor, minute}, 1, {{visitor, minute}, 0}) <=
          @rate_limit
    end
  end

  defp allow?(_), do: false

  @doc "Deletes raw events older than `days`. Returns the count removed."
  def prune(days \\ @retention_days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day)
    {n, _} = Repo.delete_all(from e in VisitEvent, where: e.inserted_at < ^cutoff)
    n
  end

  ## Reading (the admin funnel)

  @doc """
  The funnel for events and sign-ups since `since`. Visitor steps count
  distinct day-ids, so one person on three days counts three times; the
  account steps count users who signed up in the window.
  """
  def funnel(%DateTime{} = since) do
    visitors = distinct_visitors(since, nil)

    engaged =
      distinct_visitors(
        since,
        dynamic(
          [e],
          (e.name == "engage" and (e.duration_ms >= 10_000 or e.scroll_pct >= 50)) or
            e.name == "click"
        )
      )

    cta = distinct_visitors(since, dynamic([e], e.name == "click" and like(e.target, "cta-%")))

    users = signed_up_since(since)
    user_ids = Enum.map(users, & &1.id)

    reached = fn step ->
      idx = Enum.find_index(@onboarding_steps, &(&1 == step))

      Enum.count(users, fn u ->
        u.onboarding_completed or
          (Enum.find_index(@onboarding_steps, &(&1 == u.onboarding_step)) || -1) >= idx
      end)
    end

    first_entry =
      Repo.one(
        from e in Entry,
          join: p in Poet,
          on: p.id == e.poet_id,
          where: p.user_id in ^user_ids and e.status == "published",
          select: count(p.user_id, :distinct)
      )

    returned =
      Enum.count(users, fn u ->
        u.last_seen_at != nil and
          Date.after?(DateTime.to_date(u.last_seen_at), NaiveDateTime.to_date(u.inserted_at))
      end)

    [
      {"Visited any page", visitors},
      {"Stayed 10s, scrolled half a page, or clicked", engaged},
      {"Clicked a start or sign-in button", cta},
      {"Signed up", length(users)},
      {"Onboarding: picked a poet", reached.("poet")},
      {"Onboarding: set the journey", reached.("journey")},
      {"Onboarding: reached send-off", reached.("send_off")},
      {"Onboarding: finished", reached.("done")},
      {"First entry published", first_entry},
      {"Came back on a later day", returned}
    ]
  end

  # users.inserted_at is naive UTC.
  defp signed_up_since(since) do
    naive = DateTime.to_naive(since)
    Repo.all(from u in User, where: u.inserted_at >= ^naive)
  end

  defp distinct_visitors(since, nil) do
    Repo.one(
      from e in VisitEvent,
        where: e.inserted_at >= ^since and e.name == "pageview",
        select: count(e.visitor, :distinct)
    )
  end

  defp distinct_visitors(since, condition) do
    Repo.one(
      from e in VisitEvent,
        where: e.inserted_at >= ^since,
        where: ^condition,
        select: count(e.visitor, :distinct)
    )
  end

  @doc """
  Per landing path: visitors, bounces (one page view, no click, under 10s
  visible), and median visible seconds.
  """
  def pages(%DateTime{} = since, limit \\ 15) do
    views =
      Repo.all(
        from e in VisitEvent,
          where: e.inserted_at >= ^since and e.name == "pageview",
          group_by: e.path,
          order_by: [desc: count(e.visitor, :distinct)],
          limit: ^limit,
          select: {e.path, count(e.visitor, :distinct)}
      )

    paths = Enum.map(views, &elem(&1, 0))

    # A page left and returned to reports again with its running total, so
    # each visitor's time on a path is their largest report.
    durations =
      Repo.all(
        from e in VisitEvent,
          where: e.inserted_at >= ^since and e.name == "engage" and e.path in ^paths,
          group_by: [e.path, e.visitor],
          select: {e.path, max(e.duration_ms)}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    bounced = bounced_by_path(since, paths)

    Enum.map(views, fn {path, n} ->
      %{
        path: path,
        visitors: n,
        bounce_pct: pct(Map.get(bounced, path, 0), n),
        median_s: median(Map.get(durations, path, [])) |> then(&(&1 && div(&1, 1000)))
      }
    end)
  end

  # A bounce: the visitor's only page view that day was this path, they
  # clicked nothing, and no engage report says they stayed 10s.
  defp bounced_by_path(since, paths) do
    rows =
      Repo.all(
        from e in VisitEvent,
          where: e.inserted_at >= ^since,
          select: {e.visitor, e.name, e.path, e.duration_ms}
      )

    rows
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.reduce(%{}, fn {_visitor, events}, acc ->
      views = for {_, "pageview", path, _} <- events, do: path
      clicked? = Enum.any?(events, &(elem(&1, 1) == "click"))

      stayed? =
        Enum.any?(events, fn {_, name, _, d} -> name == "engage" and (d || 0) >= 10_000 end)

      case views do
        [path] when not clicked? and not stayed? ->
          if path in paths, do: Map.update(acc, path, 1, &(&1 + 1)), else: acc

        _ ->
          acc
      end
    end)
  end

  @doc "Top values of one column among page views, as `[{value, visitors}]`."
  def top(%DateTime{} = since, field, limit \\ 10)
      when field in [:referrer_host, :utm_source, :utm_campaign, :viewport] do
    Repo.all(
      from e in VisitEvent,
        where: e.inserted_at >= ^since and e.name == "pageview" and not is_nil(field(e, ^field)),
        group_by: field(e, ^field),
        order_by: [desc: count(e.visitor, :distinct)],
        limit: ^limit,
        select: {field(e, ^field), count(e.visitor, :distinct)}
    )
  end

  @doc "Click counts by data-track label: `[{label, clicks, visitors}]`."
  def clicks(%DateTime{} = since, limit \\ 20) do
    Repo.all(
      from e in VisitEvent,
        where: e.inserted_at >= ^since and e.name == "click",
        group_by: e.target,
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: {e.target, count(e.id), count(e.visitor, :distinct)}
    )
  end

  @doc "Distinct visitors per UTC day since `since`, oldest first, gaps as 0."
  def daily_visitors(%DateTime{} = since) do
    counts =
      Repo.all(
        from e in VisitEvent,
          where: e.inserted_at >= ^since and e.name == "pageview",
          group_by: fragment("date(?)", e.inserted_at),
          select: {fragment("date(?)", e.inserted_at), count(e.visitor, :distinct)}
      )
      |> Map.new(fn {d, n} -> {to_string(d), n} end)

    Date.range(DateTime.to_date(since), Date.utc_today())
    |> Enum.map(fn d -> {d, Map.get(counts, Date.to_iso8601(d), 0)} end)
  end

  @doc "Users who signed up since `since` and have not finished onboarding."
  def stuck_in_onboarding(%DateTime{} = since) do
    naive = DateTime.to_naive(since)

    Repo.all(
      from u in User,
        where: u.inserted_at >= ^naive and not u.onboarding_completed,
        order_by: [desc: u.inserted_at],
        select: %{email: u.email, step: u.onboarding_step, inserted_at: u.inserted_at}
    )
  end

  def pct(_n, 0), do: nil
  def pct(n, total), do: round(n * 100 / total)

  defp median([]), do: nil

  defp median(list) do
    sorted = list |> Enum.reject(&is_nil/1) |> Enum.sort()

    case sorted do
      [] -> nil
      _ -> Enum.at(sorted, div(length(sorted), 2))
    end
  end
end
