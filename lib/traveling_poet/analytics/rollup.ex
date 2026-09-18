defmodule TravelingPoet.Analytics.Rollup do
  @moduledoc """
  Rebuilds `funnel_days` from `visit_events` and the users who signed up,
  for the last `days` days. Run every 15 minutes by `Analytics.Server`.

  A row is written only when its numbers changed: the change stream hashes
  whole rows, timestamps included, so rewriting identical numbers would send
  every row to every receiver on every pass.

  Sources: a visitor's source for the day is the first `utm_source` (or
  `?ref=`) on their page views that day. A sign-up takes the source of the
  visitor on its `signup` event; accounts from before visit counting, or
  whose visitor had no source, count only under `"all"`.
  """

  import Ecto.Query

  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Analytics.{FunnelDay, VisitEvent}
  alias TravelingPoet.Journal.Entry
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.Repo

  @default_days 30
  @steps ~w(poet journey send_off done)

  @doc "Rebuild the last `days` days (today included). Returns `%{written: n, deleted: n}`."
  def run(days \\ @default_days, today \\ Date.utc_today()) do
    first = Date.add(today, -(days - 1))
    since = DateTime.new!(first, ~T[00:00:00], "Etc/UTC")

    events = Repo.all(from e in VisitEvent, where: e.inserted_at >= ^since)
    users = Repo.all(from u in User, where: u.inserted_at >= ^DateTime.to_naive(since))

    fresh =
      events
      |> Enum.group_by(&DateTime.to_date(&1.inserted_at))
      |> then(fn by_day ->
        Date.range(first, today)
        |> Enum.flat_map(fn day -> day_rows(day, Map.get(by_day, day, [])) end)
      end)
      |> with_accounts(users, events)
      |> Map.new(&{{&1.day, &1.source}, &1})

    existing =
      Repo.all(from f in FunnelDay, where: f.day >= ^first)
      |> Map.new(&{{&1.day, &1.source}, &1})

    written =
      Enum.count(fresh, fn {key, attrs} ->
        changeset = FunnelDay.changeset(Map.get(existing, key, %FunnelDay{}), attrs)

        cond do
          changeset.data.id && changeset.changes == %{} -> false
          true -> match?({:ok, _}, Repo.insert_or_update(changeset))
        end
      end)

    stale = existing |> Map.drop(Map.keys(fresh)) |> Map.values() |> Enum.map(& &1.id)
    {deleted, _} = Repo.delete_all(from f in FunnelDay, where: f.id in ^stale)

    %{written: written, deleted: deleted}
  end

  # The visit steps for one day: an "all" row, plus one per source seen.
  defp day_rows(day, day_events) do
    by_visitor = Enum.group_by(day_events, & &1.visitor)
    sources = Map.new(by_visitor, fn {v, evs} -> {v, source_of(evs)} end)

    segments =
      ["all" | sources |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.uniq()]

    Enum.map(segments, fn segment ->
      visitors =
        for {v, evs} <- by_visitor,
            Enum.any?(evs, &(&1.name == "pageview")),
            segment == "all" or sources[v] == segment,
            do: evs

      %{
        day: day,
        source: segment,
        visitors: length(visitors),
        engaged: Enum.count(visitors, &engaged?/1),
        cta_visitors: Enum.count(visitors, &cta?/1),
        bounced: Enum.count(visitors, &bounced?/1),
        median_visible_s: visitors |> Enum.map(&visible_ms/1) |> median() |> to_seconds()
      }
    end)
  end

  # Adds the account steps to each row. A day with sign-ups but no visit
  # rows (accounts from before counting began) still gets an "all" row.
  defp with_accounts(rows, users, events) do
    by_visitor_day = Enum.group_by(events, &{&1.visitor, DateTime.to_date(&1.inserted_at)})

    signup_source =
      for e <- events, e.name == "signup", e.user_id, into: %{} do
        {e.user_id, source_of(by_visitor_day[{e.visitor, DateTime.to_date(e.inserted_at)}])}
      end

    published = published_user_ids(Enum.map(users, & &1.id))

    by_day = Enum.group_by(users, &NaiveDateTime.to_date(&1.inserted_at))

    rows =
      rows ++
        for {day, _} <- by_day,
            not Enum.any?(rows, &(&1.day == day and &1.source == "all")),
            do: %{day: day, source: "all", visitors: 0, engaged: 0, cta_visitors: 0, bounced: 0}

    Enum.map(rows, fn row ->
      cohort =
        by_day
        |> Map.get(row.day, [])
        |> Enum.filter(&(row.source == "all" or signup_source[&1.id] == row.source))

      Map.merge(row, %{
        signups: length(cohort),
        onboarding_poet: reached(cohort, "poet"),
        onboarding_journey: reached(cohort, "journey"),
        onboarding_send_off: reached(cohort, "send_off"),
        onboarding_done: reached(cohort, "done"),
        first_entries: Enum.count(cohort, &MapSet.member?(published, &1.id)),
        returned: Enum.count(cohort, &returned?/1)
      })
    end)
  end

  defp source_of(events) do
    events
    |> Enum.filter(&(&1.name == "pageview" and &1.utm_source))
    |> Enum.min_by(& &1.id, fn -> nil end)
    |> case do
      nil -> nil
      e -> e.utm_source
    end
  end

  defp engaged?(evs) do
    Enum.any?(evs, fn e ->
      e.name == "click" or
        (e.name == "engage" and ((e.duration_ms || 0) >= 10_000 or (e.scroll_pct || 0) >= 50))
    end)
  end

  defp cta?(evs),
    do: Enum.any?(evs, &(&1.name == "click" and String.starts_with?(&1.target || "", "cta-")))

  defp bounced?(evs) do
    Enum.count(evs, &(&1.name == "pageview")) == 1 and
      not Enum.any?(evs, &(&1.name == "click")) and
      visible_ms(evs) < 10_000
  end

  # Engage reports carry a running total per page, so a visitor's time is the
  # sum over pages of each page's largest report.
  defp visible_ms(evs) do
    evs
    |> Enum.filter(&(&1.name == "engage" and &1.duration_ms))
    |> Enum.group_by(& &1.path, & &1.duration_ms)
    |> Enum.map(fn {_path, ds} -> Enum.max(ds) end)
    |> Enum.sum()
  end

  defp reached(users, step) do
    idx = Enum.find_index(@steps, &(&1 == step))

    Enum.count(users, fn u ->
      u.onboarding_completed or (Enum.find_index(@steps, &(&1 == u.onboarding_step)) || -1) >= idx
    end)
  end

  defp returned?(u) do
    u.last_seen_at != nil and
      Date.after?(DateTime.to_date(u.last_seen_at), NaiveDateTime.to_date(u.inserted_at))
  end

  defp published_user_ids([]), do: MapSet.new()

  defp published_user_ids(ids) do
    Repo.all(
      from e in Entry,
        join: p in Poet,
        on: p.id == e.poet_id,
        where: p.user_id in ^ids and e.status == "published",
        distinct: true,
        select: p.user_id
    )
    |> MapSet.new()
  end

  defp median([]), do: nil

  defp median(list) do
    sorted = Enum.sort(list)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp to_seconds(nil), do: nil
  defp to_seconds(ms), do: div(ms, 1000)
end
