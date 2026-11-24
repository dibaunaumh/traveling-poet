defmodule TravelingPoet.NearHome do
  @moduledoc """
  "Near you" (card-71): once a week the poet looks for things the reader can
  actually go to, near their home: events, exhibitions, markets,
  performances, places and outings in the coming days that fit their tastes.

  The app decides when (`NearHome.Cadence`, after a published daily page),
  frames the task in one headless turn (`request/3`, modelled on
  `Guide.MorePlaces`), and checks every pick the poet sends back
  (`ingest/4`): a live link, dates inside the window, and a location within
  reach of home, and nothing suggested in the last `@memory_weeks` weeks
  (the poet does not reliably remember its earlier weeks, so the app tells
  it and holds it to that). The batch is the reader's alone: it reveals where they
  live, so it hangs off the user, never the public journal, and the change
  stream leaves it out.

  Away from home (card-78) the same turn looks around where the reader is
  instead (`anchor/1`, `NearHome.Away`), and the batch remembers the place
  it was found around.

  Included in the day's credit; capped at one turn a day (`Usage` kind
  "near_home"), and that turn counts as the sprite being busy for other
  headless turns.
  """

  import Ecto.Query
  require Logger

  alias TravelingPoet.{Credits, Geo, Geocoder, LinkCheck, Locale, Markers, Repo, Topics, Usage}
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.NearHome.{Away, Cadence, Pick}

  @radius_km 40
  @window_days 10
  @max_picks 8
  @usage_kind "near_home"
  @reply_timeout_ms 15 * 60 * 1000
  # How far back a pick counts as already suggested
  @memory_weeks 8

  def radius_km, do: @radius_km
  def window_days, do: @window_days
  def usage_kind, do: @usage_kind

  ## Reads

  @doc "The reader's latest batch, in the poet's order."
  def latest(user_id) do
    case last_batch_on(user_id) do
      nil -> []
      date -> batch(user_id, date)
    end
  end

  @doc "Every pick the reader was sent, newest batch first."
  def list(user_id) do
    Pick
    |> where(user_id: ^user_id)
    |> order_by(desc: :week_of, asc: :position, asc: :id)
    |> Repo.all()
  end

  @doc "The date of the latest batch, or nil."
  def last_batch_on(user_id) do
    Pick
    |> where(user_id: ^user_id)
    |> select([p], max(p.week_of))
    |> Repo.one()
  end

  @doc """
  What the reader can still go to: the latest batch while it is under a
  week old, without the picks that are already over. `[]` otherwise.
  """
  def this_week(user_id, %Date{} = today \\ Date.utc_today()) do
    case last_batch_on(user_id) do
      nil ->
        []

      date ->
        if Date.diff(today, date) < 7,
          do: Enum.reject(batch(user_id, date), &over?(&1, today)),
          else: []
    end
  end

  @doc """
  Whether the poet is out looking right now: a near-home turn started in
  the last `@reply_timeout_ms` and no batch has landed since. Lets a page
  opened mid-search show the wait instead of offering to start another.
  """
  def looking?(user_id, now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -@reply_timeout_ms, :millisecond)

    started =
      TravelingPoet.Usage.UsageEvent
      |> where([e], e.user_id == ^user_id and e.kind == @usage_kind and e.occurred_at > ^since)
      |> select([e], max(e.occurred_at))
      |> Repo.one()

    landed =
      Pick
      |> where(user_id: ^user_id)
      |> select([p], max(p.inserted_at))
      |> Repo.one()

    cond do
      is_nil(started) -> false
      is_nil(landed) -> true
      true -> NaiveDateTime.compare(landed, DateTime.to_naive(started)) == :lt
    end
  end

  @doc "Whether a pick's last day has passed."
  def over?(%Pick{ends_on: %Date{} = ends_on}, today), do: Date.compare(ends_on, today) == :lt
  def over?(_pick, _today), do: false

  @doc "Turns the weekly picks on or off for this reader."
  def set_enabled(%User{} = user, enabled?) when is_boolean(enabled?),
    do: TravelingPoet.Accounts.update_user(user, %{near_home: enabled?})

  defp batch(user_id, date) do
    Pick
    |> where(user_id: ^user_id, week_of: ^date)
    |> order_by(asc: :position, asc: :id)
    |> Repo.all()
  end

  ## When

  def home?(%User{home_lat: lat, home_lng: lng}), do: is_number(lat) and is_number(lng)

  @doc """
  The place Near you looks around: where the reader is when they are away
  from home (`Away.here/2`), else home, as `%{name:, lat:, lng:, away?:}`.
  Nil without a home.
  """
  def anchor(%User{} = user) do
    cond do
      not home?(user) -> nil
      here = Away.here(user) -> here
      true -> %{name: user.home_place_name, lat: user.home_lat, lng: user.home_lng, away?: false}
    end
  end

  @doc """
  Whether this reader's poet should look near them today: the weekly
  cadence, or a place away from home it has not looked around yet.
  """
  def due?(%User{} = user, %Date{} = today \\ Date.utc_today()) do
    Cadence.due?(
      %{
        home?: home?(user),
        enabled?: user.near_home != false,
        last_batch_on: last_batch_on(user.id)
      },
      today
    ) or Away.due?(user, today)
  end

  @doc """
  Called once a daily page is published. Starts the week's near-home turn
  when it is due; does nothing otherwise, or when switched off app-wide
  (`:near_home_enabled`, off in test).
  """
  def after_publish(%User{} = user, poet) do
    if Application.get_env(:traveling_poet, :near_home_enabled, true) and due?(user) do
      case request(user, poet, after_run: true) do
        {:ok, :started} -> :started
        {:error, reason} -> Logger.info("NearHome: poet #{poet.id} not asked: #{reason}")
      end
    end

    :ok
  end

  ## The turn

  @doc """
  Asks the poet for the week's picks near home, in a turn of its own, and
  reports `{:near_home_turn, result}` to `reply_to` when it ends. `after_run:
  true` skips the busy check: the daily run that made the sprite look busy
  is the one that just finished. Returns `{:ok, :started}` or `{:error,
  reason}`, reason one of `:no_home`, `:off`, `:credits`, `:cap`, `:busy`.
  """
  def request(%User{} = user, poet, opts \\ []) do
    reply_to = Keyword.get(opts, :reply_to)

    with :ok <- gate(user, poet, Keyword.get(opts, :after_run, false)) do
      # The cap and the busy window both read this row: it must be written.
      {:ok, _} = Usage.record(user.id, @usage_kind)
      note = note(user, poet, Date.utc_today())
      session = Application.get_env(:traveling_poet, :agent_session, TravelingPoet.AgentSession)

      # Pages open elsewhere show the wait (and its end) too.
      Phoenix.PubSub.broadcast(TravelingPoet.PubSub, "user:#{user.id}", {:near_home, :looking})

      Task.start(fn ->
        Logger.info("NearHome: asking poet #{poet.id} for picks near #{anchor(user).name}")
        result = session.run(user, note, channel: "system", reply_timeout_ms: @reply_timeout_ms)

        case result do
          {:ok, reply} -> rescue_written_call(user, poet, reply)
          other -> Logger.warning("NearHome: poet #{poet.id}: #{inspect(other, limit: 200)}")
        end

        Phoenix.PubSub.broadcast(TravelingPoet.PubSub, "user:#{user.id}", {:near_home, :done})
        if reply_to, do: send(reply_to, {:near_home_turn, result})
      end)

      {:ok, :started}
    end
  end

  @doc """
  A poet that ran out of output mid-turn sometimes writes its
  `near_home_put` call as text ("[tool call] near_home_put({...})") instead
  of making it, and the turn ends with nothing saved (Nam, Ashdod,
  2026-11-24). When the turn's reply holds such a call and no batch landed
  today, its picks go through `ingest/4` as if the tool had been called:
  every check still applies. Returns `{:ok, result}` when it ingested,
  else `:none`.
  """
  def rescue_written_call(%User{} = user, poet, reply, %Date{} = today \\ Date.utc_today()) do
    with true <- is_binary(reply),
         [_, rest] <- String.split(reply, "near_home_put(", parts: 2),
         {:ok, %{"picks" => [_ | _] = picks}} <- first_json_object(rest),
         true <- last_batch_on(user.id) != today,
         {:ok, result} <- ingest(user, poet, picks, today) do
      Logger.warning(
        "NearHome: poet #{poet.id} wrote near_home_put as text; ingested, " <>
          "kept #{length(result.kept)} of #{length(picks)}"
      )

      {:ok, result}
    else
      _ -> :none
    end
  end

  # The JSON object at the start of `text` (after whitespace), ignoring
  # whatever follows it: braces are counted outside strings.
  defp first_json_object(text) do
    text = String.trim_leading(text)

    if String.starts_with?(text, "{") do
      case object_end(text, 0, 0, false, false) do
        nil -> :error
        len -> Jason.decode(binary_part(text, 0, len))
      end
    else
      :error
    end
  end

  defp object_end(text, i, depth, in_string?, escaped?) when i < byte_size(text) do
    char = :binary.at(text, i)

    cond do
      in_string? and escaped? -> object_end(text, i + 1, depth, true, false)
      in_string? and char == ?\\ -> object_end(text, i + 1, depth, true, true)
      in_string? and char == ?" -> object_end(text, i + 1, depth, false, false)
      in_string? -> object_end(text, i + 1, depth, true, false)
      char == ?" -> object_end(text, i + 1, depth, true, false)
      char == ?{ -> object_end(text, i + 1, depth + 1, false, false)
      char == ?} and depth == 1 -> i + 1
      char == ?} -> object_end(text, i + 1, depth - 1, false, false)
      true -> object_end(text, i + 1, depth, false, false)
    end
  end

  defp object_end(_text, _i, _depth, _in_string?, _escaped?), do: nil

  defp gate(user, poet, after_run?) do
    anchor = anchor(user)

    cond do
      is_nil(anchor) ->
        {:error, :no_home}

      # Away, the reader's "notice where I am" switch is the consent
      not anchor.away? and user.near_home == false ->
        {:error, :off}

      Credits.exhausted?(user, poet) ->
        {:error, :credits}

      not Usage.within_budget?(user, @usage_kind) ->
        {:error, :cap}

      not after_run? and Markers.Delivery.busy?(user.id, DateTime.utc_now(), chat: false) ->
        {:error, :busy}

      true ->
        :ok
    end
  end

  @doc "What the poet is sent: an app note, in the shape of `Asks.frame_reply/2`."
  def note(%User{} = user, poet, %Date{} = today) do
    until = Date.add(today, @window_days)

    tastes =
      poet.id
      |> Topics.list_active()
      |> Enum.map(& &1.label)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.take(8)

    tastes_line =
      case tastes do
        [] -> "Their tastes are in get_poet_context."
        labels -> "What they are into: #{Enum.join(labels, "; ")} (more in get_poet_context)."
      end

    memory_line = memory_line(user.id, today)
    anchor = anchor(user)

    {opening, around, question} =
      if anchor.away? do
        {"[From the app: your companion is away from home right now. " <>
           "#{if anchor[:source] == :calendar, do: "A trip on their calendar puts them", else: "Their phone says they are"} " <>
           "in #{anchor.name || "a place far from home"} " <>
           "(#{coord(anchor.lat)}, #{coord(anchor.lng)}); home is #{user.home_place_name}. " <>
           "Look around where they are now for things they can actually go to while they " <>
           "are there, the next few days first.", "of where they are",
         "What is on around #{Away.display_name(anchor.name, anchor.lat, anchor.lng)}?"}
      else
        {"[From the app: once a week you look near your companion's home, for things they " <>
           "can actually go to. They live in #{user.home_place_name} " <>
           "(#{coord(user.home_lat)}, #{coord(user.home_lng)}).", "of home",
         "What is on near home this week?"}
      end

    opening <>
      " #{tastes_line} " <>
      "Search the web for events, exhibitions, markets, performances, places and outings " <>
      "within #{@radius_km} km #{around}, happening between #{Date.to_iso8601(today)} and " <>
      "#{Date.to_iso8601(until)}, that fit them: the local listings, venues' own pages, " <>
      "the city's calendar. Cite only pages you actually fetched. Each pick needs that page's " <>
      "URL, its dates (starts_on and ends_on, YYYY-MM-DD) or, for a place open all week, " <>
      "when_text, and a postal address. Write each blurb (one or two sentences: why THIS, for " <>
      "THEM) in #{Locale.name(user.locale)}; keep names as the venue writes them. " <>
      memory_line <>
      "Then call near_home_put once with three to six picks; if the reply drops some, fix them and send " <>
      "the whole list again. Do not travel, do not write or change a journal page. Then tell " <>
      "them in one short line what you found.] " <> question
  end

  # What the poet must not repeat and what the reader made of earlier weeks:
  # the picks of the last weeks, the ones they saved and the ones they
  # waved off. Empty for a first week.
  defp memory_line(user_id, today) do
    earlier =
      user_id
      |> earlier_picks(today)
      |> Map.values()
      |> Enum.sort_by(&{-Date.to_gregorian_days(&1.week_of), &1.position, &1.id})
      |> Enum.map(& &1.name)

    %{saved: saved, passed: passed} = TravelingPoet.Bookmarks.near_verdicts(user_id)

    [
      earlier != [] &&
        "Already suggested in earlier weeks, so do not suggest again: #{names(earlier)}. ",
      saved != [] && "They saved these, so more like them: #{names(saved)}. ",
      passed != [] && "They said not for them to these, so steer away: #{names(passed)}. "
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join()
  end

  defp names(list), do: list |> Enum.uniq() |> Enum.take(30) |> Enum.join("; ")

  @doc """
  The picks of the batches before `today` within `@memory_weeks` weeks, by
  their name as compared (`same_name/1`), the newest of each name.
  """
  def earlier_picks(user_id, %Date{} = today) do
    since = Date.add(today, -7 * @memory_weeks)

    Pick
    |> where([p], p.user_id == ^user_id and p.week_of < ^today and p.week_of >= ^since)
    |> order_by(asc: :week_of)
    |> Repo.all()
    |> Map.new(&{same_name(&1.name), &1})
  end

  @doc "A pick's name as two weeks' picks are compared: case and spacing aside."
  def same_name(name) when is_binary(name),
    do: name |> String.downcase() |> String.split() |> Enum.join(" ")

  defp coord(x) when is_number(x), do: :erlang.float_to_binary(x / 1, decimals: 4)

  ## The poet's answer

  @doc """
  Checks the poet's picks and stores the ones that pass as today's batch,
  replacing an earlier batch of the same day. A pick is dropped, with the
  reason, when it has no name or link, was suggested in an earlier week,
  has a dead link, no dates and no when_text, dates outside the window, or
  no location within reach of home.
  Nothing is replaced when every pick is dropped.

  Distances are from `anchor/1`: where the reader is when away (the batch
  then records that place), else home.

  Returns `{:ok, %{kept: [Pick], dropped: [%{name, reason}]}}` or
  `{:error, :no_home}`.
  """
  def ingest(%User{} = user, poet, picks, %Date{} = today \\ Date.utc_today())
      when is_list(picks) do
    if anchor = anchor(user) do
      picks = Enum.take(picks, @max_picks)
      dead = dead_links(picks)
      earlier = earlier_picks(user.id, today)

      {kept, dropped} =
        picks
        |> Enum.with_index()
        |> Enum.reduce({[], []}, fn {raw, i}, {kept, dropped} ->
          case check(raw, anchor, today, dead, earlier) do
            {:ok, attrs} ->
              {[attrs |> Map.put(:position, i) |> Map.merge(around(anchor)) | kept], dropped}

            {:error, reason} ->
              {kept, [%{name: name_of(raw), reason: reason} | dropped]}
          end
        end)

      kept = Enum.reverse(kept)
      dropped = Enum.reverse(dropped)
      # A resend that fixes dropped picks replaces the day's batch; the
      # reader hears about the day's batch once.
      first_today? = last_batch_on(user.id) != today
      stored = if kept == [], do: [], else: replace_batch(user, poet, today, kept)

      if stored != [] do
        Phoenix.PubSub.broadcast(TravelingPoet.PubSub, "user:#{user.id}", {:near_home, today})

        if first_today? do
          Phoenix.PubSub.broadcast(
            TravelingPoet.PubSub,
            "near_home",
            {:near_home_ready, user.id, today}
          )
        end
      end

      {:ok, %{kept: stored, dropped: dropped}}
    else
      {:error, :no_home}
    end
  end

  @doc "Replaces the reader's batch for `date` with these picks (attribute maps)."
  def replace_batch(%User{} = user, poet, %Date{} = date, picks) do
    {:ok, stored} =
      Repo.transaction(fn ->
        Pick |> where(user_id: ^user.id, week_of: ^date) |> Repo.delete_all()

        Enum.map(picks, fn attrs ->
          %Pick{}
          |> Pick.changeset(
            Map.merge(attrs, %{user_id: user.id, poet_id: poet.id, week_of: date})
          )
          |> Repo.insert!()
        end)
      end)

    stored
  end

  defp around(%{away?: true} = anchor),
    do: %{around_name: anchor.name, around_lat: anchor.lat, around_lng: anchor.lng}

  defp around(_home), do: %{}

  defp dead_links(picks) do
    urls = for p <- picks, url = str(p, "url"), do: url

    case LinkCheck.validate_all(urls) do
      :ok -> MapSet.new()
      {:error, bad} -> MapSet.new(bad)
    end
  end

  defp check(raw, anchor, today, dead, earlier) when is_map(raw) do
    name = str(raw, "name")
    url = str(raw, "url")

    with {:name, n} when is_binary(n) <- {:name, name},
         {:repeat, nil} <- {:repeat, earlier[same_name(n)]},
         {:url, u} when is_binary(u) <- {:url, url},
         {:dead, false} <- {:dead, MapSet.member?(dead, u)},
         {:ok, starts_on, ends_on} <- dates(raw, today),
         {:ok, location} <- locate(raw, anchor) do
      {:ok,
       %{
         name: String.slice(name, 0, 200),
         url: url,
         kind: Pick.normalize_kind(raw["kind"]),
         starts_on: starts_on,
         ends_on: ends_on,
         when_text: raw |> str("when_text") |> slice(120),
         place_name: str(raw, "place_name"),
         address: str(raw, "address"),
         blurb: str(raw, "blurb"),
         lat: location.lat,
         lng: location.lng,
         distance_km: Float.round(location.distance_km, 1)
       }}
    else
      {:name, _} ->
        {:error, "a name is required"}

      {:repeat, pick} ->
        {:error, "already suggested the week of #{pick.week_of}; find something new"}

      {:url, _} ->
        {:error, "the page you read it on (url) is required"}

      {:dead, true} ->
        {:error, "the link is dead; cite a page you fetched"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check(_raw, _user, _today, _dead, _earlier), do: {:error, "not a pick"}

  defp dates(raw, today) do
    until = Date.add(today, @window_days)
    starts_on = date(raw["starts_on"])
    ends_on = date(raw["ends_on"]) || starts_on
    when_text = str(raw, "when_text")

    cond do
      is_nil(starts_on) and is_nil(ends_on) and is_nil(when_text) ->
        {:error, "needs its dates (starts_on, ends_on) or, for a place open all week, when_text"}

      ends_on && Date.compare(ends_on, today) == :lt ->
        {:error, "it is over (ended #{Date.to_iso8601(ends_on)})"}

      starts_on && Date.compare(starts_on, until) == :gt ->
        {:error, "it starts after #{Date.to_iso8601(until)}, outside this week's window"}

      true ->
        {:ok, starts_on, ends_on}
    end
  end

  # Where it is: the poet's coordinates when they put it near the anchor (home,
  # or where the reader is when away), else the address (or the venue's name
  # in that town) on the map.
  defp locate(raw, anchor) do
    given =
      case {raw["lat"], raw["lng"]} do
        {lat, lng} when is_number(lat) and is_number(lng) -> %{lat: lat / 1, lng: lng / 1}
        _ -> nil
      end

    cond do
      given && distance(given, anchor) <= @radius_km * 1.5 ->
        {:ok, Map.put(given, :distance_km, distance(given, anchor))}

      query = geocode_query(raw, anchor) ->
        case first_within_reach(geocode_fallbacks(query), anchor) do
          {:ok, found} ->
            {:ok, found}

          {:far, km} ->
            {:error, "#{round(km)} km from #{measured_from(anchor)}; keep to #{@radius_km} km"}

          :not_found ->
            {:error, "could not find \"#{query}\" on a map; give its full postal address"}
        end

      true ->
        {:error, "needs a postal address"}
    end
  end

  defp geocode_query(raw, anchor) do
    cond do
      address = str(raw, "address") -> address
      (place = str(raw, "place_name")) && anchor.name -> "#{place}, #{anchor.name}"
      true -> nil
    end
  end

  # Nominatim knows many streets only by their local name, so an English
  # postal address abroad often finds nothing ("27 Shaul Hamelech Blvd.,
  # Tel Aviv"; Ashdod, 2026-11-24). Simpler forms are tried in turn: without
  # house numbers and postcodes, the street or venue with the town, the
  # venue alone ("Tel Aviv Museum of Art"), then the town. Each goes through
  # the geocoder's cache and limiter.
  @doc false
  def geocode_fallbacks(query) do
    parts =
      query
      |> String.split(",")
      |> Enum.map(&(&1 |> String.replace(~r/\b\d[\w-]*\b/u, "") |> squeeze()))
      |> Enum.reject(&(&1 == ""))

    simplified =
      case parts do
        [] ->
          []

        [one] ->
          [one]

        [first | _] ->
          [Enum.join(parts, ", "), "#{first}, #{List.last(parts)}", first, List.last(parts)]
      end

    Enum.uniq([String.trim(query) | simplified])
  end

  defp squeeze(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  # The first form found within reach; else how far the first one found
  # was, so the poet hears it picked a place too far away.
  defp first_within_reach(queries, anchor) do
    Enum.reduce_while(queries, :not_found, fn query, acc ->
      case Geocoder.locate(query) do
        {:ok, %{lat: lat, lng: lng}} ->
          found = %{lat: lat, lng: lng}
          km = distance(found, anchor)

          cond do
            km <= @radius_km * 1.5 -> {:halt, {:ok, Map.put(found, :distance_km, km)}}
            acc == :not_found -> {:cont, {:far, km}}
            true -> {:cont, acc}
          end

        _ ->
          {:cont, acc}
      end
    end)
  end

  defp measured_from(%{away?: true, name: name}) when is_binary(name), do: Away.short_name(name)
  defp measured_from(%{away?: true}), do: "where they are"
  defp measured_from(_home), do: "home"

  defp distance(%{lat: lat, lng: lng}, anchor),
    do: Geo.distance_km(lat, lng, anchor.lat, anchor.lng)

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(String.slice(String.trim(value), 0, 10)) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp date(_), do: nil

  defp str(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) -> if String.trim(v) == "", do: nil, else: String.trim(v)
      _ -> nil
    end
  end

  defp slice(nil, _), do: nil
  defp slice(text, n), do: String.slice(text, 0, n)

  defp name_of(raw) when is_map(raw), do: str(raw, "name") || "(no name)"
  defp name_of(_), do: "(no name)"
end
