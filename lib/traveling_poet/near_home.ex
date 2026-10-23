defmodule TravelingPoet.NearHome do
  @moduledoc """
  "Near you" (card-71): once a week the poet looks for things the reader can
  actually go to, near their home: events, exhibitions, markets,
  performances, places and outings in the coming days that fit their tastes.

  The app decides when (`NearHome.Cadence`, after a published daily page),
  frames the task in one headless turn (`request/3`, modelled on
  `Guide.MorePlaces`), and checks every pick the poet sends back
  (`ingest/4`): a live link, dates inside the window, and a location within
  reach of home. The batch is the reader's alone: it reveals where they
  live, so it hangs off the user, never the public journal, and the change
  stream leaves it out.

  Included in the day's credit; capped at one turn a day (`Usage` kind
  "near_home"), and that turn counts as the sprite being busy for other
  headless turns.
  """

  import Ecto.Query
  require Logger

  alias TravelingPoet.{Credits, Geo, Geocoder, LinkCheck, Locale, Markers, Repo, Topics, Usage}
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.NearHome.{Cadence, Pick}

  @radius_km 40
  @window_days 10
  @max_picks 8
  @usage_kind "near_home"
  @reply_timeout_ms 15 * 60 * 1000

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

  defp batch(user_id, date) do
    Pick
    |> where(user_id: ^user_id, week_of: ^date)
    |> order_by(asc: :position, asc: :id)
    |> Repo.all()
  end

  ## When

  def home?(%User{home_lat: lat, home_lng: lng}), do: is_number(lat) and is_number(lng)

  @doc "Whether this reader's poet should look near home today."
  def due?(%User{} = user, %Date{} = today \\ Date.utc_today()) do
    Cadence.due?(
      %{
        home?: home?(user),
        enabled?: user.near_home != false,
        last_batch_on: last_batch_on(user.id)
      },
      today
    )
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

      Task.start(fn ->
        Logger.info("NearHome: asking poet #{poet.id} for picks near #{user.home_place_name}")
        result = session.run(user, note, channel: "system", reply_timeout_ms: @reply_timeout_ms)

        case result do
          {:ok, _} -> :ok
          other -> Logger.warning("NearHome: poet #{poet.id}: #{inspect(other, limit: 200)}")
        end

        if reply_to, do: send(reply_to, {:near_home_turn, result})
      end)

      {:ok, :started}
    end
  end

  defp gate(user, poet, after_run?) do
    cond do
      not home?(user) ->
        {:error, :no_home}

      user.near_home == false ->
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

    "[From the app: once a week you look near your companion's home, for things they " <>
      "can actually go to. They live in #{user.home_place_name} " <>
      "(#{coord(user.home_lat)}, #{coord(user.home_lng)}). #{tastes_line} " <>
      "Search the web for events, exhibitions, markets, performances, places and outings " <>
      "within #{@radius_km} km of home, happening between #{Date.to_iso8601(today)} and " <>
      "#{Date.to_iso8601(until)}, that fit them: the local listings, venues' own pages, " <>
      "the city's calendar. Cite only pages you actually fetched. Each pick needs that page's " <>
      "URL, its dates (starts_on and ends_on, YYYY-MM-DD) or, for a place open all week, " <>
      "when_text, and a postal address. Write each blurb (one or two sentences: why THIS, for " <>
      "THEM) in #{Locale.name(user.locale)}; keep names as the venue writes them. Then call " <>
      "near_home_put once with three to six picks; if the reply drops some, fix them and send " <>
      "the whole list again. Do not travel, do not write or change a journal page. Then tell " <>
      "them in one short line what you found.] What is on near home this week?"
  end

  defp coord(x) when is_number(x), do: :erlang.float_to_binary(x / 1, decimals: 4)

  ## The poet's answer

  @doc """
  Checks the poet's picks and stores the ones that pass as today's batch,
  replacing an earlier batch of the same day. A pick is dropped, with the
  reason, when it has no name or link, a dead link, no dates and no
  when_text, dates outside the window, or no location within reach of home.
  Nothing is replaced when every pick is dropped.

  Returns `{:ok, %{kept: [Pick], dropped: [%{name, reason}]}}` or
  `{:error, :no_home}`.
  """
  def ingest(%User{} = user, poet, picks, %Date{} = today \\ Date.utc_today())
      when is_list(picks) do
    if home?(user) do
      picks = Enum.take(picks, @max_picks)
      dead = dead_links(picks)

      {kept, dropped} =
        picks
        |> Enum.with_index()
        |> Enum.reduce({[], []}, fn {raw, i}, {kept, dropped} ->
          case check(raw, user, today, dead) do
            {:ok, attrs} -> {[Map.put(attrs, :position, i) | kept], dropped}
            {:error, reason} -> {kept, [%{name: name_of(raw), reason: reason} | dropped]}
          end
        end)

      kept = Enum.reverse(kept)
      dropped = Enum.reverse(dropped)
      stored = if kept == [], do: [], else: replace_batch(user, poet, today, kept)

      if stored != [] do
        Phoenix.PubSub.broadcast(TravelingPoet.PubSub, "user:#{user.id}", {:near_home, today})
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

  defp dead_links(picks) do
    urls = for p <- picks, url = str(p, "url"), do: url

    case LinkCheck.validate_all(urls) do
      :ok -> MapSet.new()
      {:error, bad} -> MapSet.new(bad)
    end
  end

  defp check(raw, user, today, dead) when is_map(raw) do
    name = str(raw, "name")
    url = str(raw, "url")

    with {:name, n} when is_binary(n) <- {:name, name},
         {:url, u} when is_binary(u) <- {:url, url},
         {:dead, false} <- {:dead, MapSet.member?(dead, u)},
         {:ok, starts_on, ends_on} <- dates(raw, today),
         {:ok, location} <- locate(raw, user) do
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
      {:name, _} -> {:error, "a name is required"}
      {:url, _} -> {:error, "the page you read it on (url) is required"}
      {:dead, true} -> {:error, "the link is dead; cite a page you fetched"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check(_raw, _user, _today, _dead), do: {:error, "not a pick"}

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

  # Where it is: the poet's coordinates when they put it near home, else the
  # address (or the venue's name in the home town) on the map.
  defp locate(raw, user) do
    given =
      case {raw["lat"], raw["lng"]} do
        {lat, lng} when is_number(lat) and is_number(lng) -> %{lat: lat / 1, lng: lng / 1}
        _ -> nil
      end

    cond do
      given && distance(given, user) <= @radius_km * 1.5 ->
        {:ok, Map.put(given, :distance_km, distance(given, user))}

      query = geocode_query(raw, user) ->
        case Geocoder.locate(query) do
          {:ok, %{lat: lat, lng: lng}} ->
            found = %{lat: lat, lng: lng}
            km = distance(found, user)

            if km <= @radius_km * 1.5,
              do: {:ok, Map.put(found, :distance_km, km)},
              else: {:error, "#{round(km)} km from home; keep to #{@radius_km} km"}

          _ ->
            {:error, "could not find \"#{query}\" on a map; give its full postal address"}
        end

      true ->
        {:error, "needs a postal address"}
    end
  end

  defp geocode_query(raw, user) do
    cond do
      address = str(raw, "address") -> address
      place = str(raw, "place_name") -> "#{place}, #{user.home_place_name}"
      true -> nil
    end
  end

  defp distance(%{lat: lat, lng: lng}, user),
    do: Geo.distance_km(lat, lng, user.home_lat, user.home_lng)

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
