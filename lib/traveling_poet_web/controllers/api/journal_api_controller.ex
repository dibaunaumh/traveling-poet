defmodule TravelingPoetWeb.Api.JournalApiController do
  use TravelingPoetWeb, :controller

  require Logger

  alias TravelingPoet.{Guide, Journal, LinkCheck, Markers, Poets, Preferences, Topics}
  alias TravelingPoet.Markers.Guard
  alias TravelingPoet.Guide.Geocoding
  alias TravelingPoet.Journal.Marker

  # A day's finds, not a directory. The skill asks for 2-4; this is the
  # backstop against a model that decides to list everything it walked past.
  @max_places 8
  # Link checks probe live URLs with a 6s timeout each (LinkCheck), so a
  # full list run serially could hold the agent's request open for most of a
  # minute.
  @link_check_concurrency 6
  # Matches Entry's validation. Over-long teasers are cut, never rejected: a
  # fumbled field must not cost the poet its entry.
  @teaser_max 140

  def upsert_entry(conn, %{"entry_date" => date_str} = params) do
    with_poet_and_date(conn, date_str, fn poet, date ->
      attrs =
        params
        |> Map.take(["title", "teaser", "place_name", "lat", "lng", "weather", "sources"])
        |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
        |> trim_teaser()

      case Journal.upsert_entry(poet.id, date, attrs) do
        {:ok, entry} ->
          case Topics.link_entry(entry, params) do
            {:ok, excursion} ->
              prompt = maybe_attach_prompt(entry, params["prompt"])

              json(conn, %{
                ok: true,
                entry_id: entry.id,
                entry_date: entry.entry_date,
                status: entry.status,
                prompt_accepted: prompt,
                excursion_linked: not is_nil(excursion)
              })

            # The entry is saved; only the excursion id was wrong. Loud, so
            # the poet fixes the id instead of publishing a place entry on a
            # day the app sent it off the road.
            {:error, reason} ->
              conn
              |> put_status(422)
              |> json(%{
                error:
                  "entry saved, but #{reason}: pass the excursion_id or topic_id from " <>
                    "travel.excursion in get_poet_context",
                entry_id: entry.id
              })
          end

        {:error, changeset} ->
          conn |> put_status(422) |> json(%{error: changeset_errors(changeset)})
      end
    end)
  end

  def upsert_entry(conn, _params) do
    conn |> put_status(422) |> json(%{error: "entry_date (YYYY-MM-DD) is required"})
  end

  defp trim_teaser(%{teaser: teaser} = attrs) when is_binary(teaser) do
    %{attrs | teaser: teaser |> String.trim() |> cut_at_word(@teaser_max)}
  end

  defp trim_teaser(attrs), do: attrs

  # An over-long teaser ends on a whole word and an ellipsis, not mid-word:
  # it is the notification text, and "I wasn'" is not a hook.
  defp cut_at_word(text, max) do
    if String.length(text) <= max do
      text
    else
      text
      |> String.slice(0, max - 1)
      |> String.replace(~r/\s+\S*$/u, "")
      |> Kernel.<>("…")
    end
  end

  # A question the poet wants to ask under today's entry. Optional, and a
  # malformed one is dropped rather than rejected: the fleet model fumbles
  # structured output often enough (see the illustration wiring) that a bad
  # prompt object must never cost the poet its entry. The app's own rotation
  # still fills the slot, so a dropped prompt means a duller question, not no
  # question.
  defp maybe_attach_prompt(entry, prompt) when is_map(prompt) do
    case Preferences.attach_agent_prompt(entry, prompt) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.info("Ignoring malformed agent prompt for entry #{entry.id}: #{inspect(reason)}")
        false
    end
  end

  defp maybe_attach_prompt(_entry, _prompt), do: false

  def put_sections(conn, %{"date" => date_str, "sections" => sections}) when is_list(sections) do
    with_poet_and_date(conn, date_str, fn poet, date ->
      case validate_section_links(sections) do
        {:error, bad_urls} ->
          conn
          |> put_status(422)
          |> json(%{
            error:
              "these cited links are unreachable: #{Enum.join(bad_urls, ", ")}. " <>
                "Only cite URLs taken from pages you actually fetched and read — " <>
                "search for the organization's real site and confirm it loads before citing."
          })

        :ok ->
          do_put_sections(conn, poet, date, sections, date_str)
      end
    end)
  end

  def put_sections(conn, _params) do
    conn |> put_status(422) |> json(%{error: "sections (list) is required"})
  end

  defp do_put_sections(conn, poet, date, sections, date_str) do
    case Journal.get_entry_preloaded(poet.id, date) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{error: "no entry for #{date_str}; call journal_upsert_entry first"})

      entry ->
        {sections, kept} = guard_revision(entry, sections)

        case Journal.replace_sections(entry, sections) do
          {:ok, saved} ->
            json(conn, put_sections_result(saved, kept))

          {:error, reason} ->
            conn |> put_status(422) |> json(%{error: inspect(reason)})
        end
    end
  end

  # A re-put of a published entry with feedback markers on it is a revision:
  # only the marked passages may change (Markers.Guard). Drafts, and revisions
  # the reader asked for in chat with no markers in play, pass through.
  defp guard_revision(%{status: "published"} = entry, sections) do
    case Guard.active_markers(Markers.list_markers(entry.id)) do
      [] -> {sections, []}
      markers -> Guard.protect(entry.sections, sections, markers)
    end
  end

  defp guard_revision(_entry, sections), do: {sections, []}

  defp put_sections_result(saved, []), do: %{ok: true, section_count: length(saved)}

  defp put_sections_result(saved, kept) do
    %{
      ok: true,
      section_count: length(saved),
      kept_as_written: kept,
      note:
        "These sections carried no marker asking for a change, so they were kept exactly " <>
          "as the reader read them. Do not describe them as changed in your reply."
    }
  end

  defp validate_section_links(sections) do
    sections
    |> Enum.flat_map(fn section ->
      metadata = section["metadata"] || section[:metadata] || %{}

      case metadata["source_url"] || metadata[:source_url] do
        url when is_binary(url) and url != "" -> [url]
        _ -> []
      end
    end)
    |> TravelingPoet.LinkCheck.validate_all()
  end

  @doc """
  Replaces the day's guide places.

  Its own endpoint rather than a rider on `put_sections` for the same reason
  entry_prompts are their own table: the skill tells the poet to re-send its
  full section list after illustrating, so anything carried in that list gets
  wiped mid-run.

  Deliberately forgiving. A place with a dead link is dropped and named in the
  response; the rest are saved. Refusing the whole list over one bad URL would
  cost the reader eight good recommendations to punish one.
  """
  def put_places(conn, %{"date" => date_str, "places" => places}) when is_list(places) do
    with_poet_and_date(conn, date_str, fn poet, date ->
      case Journal.get_entry(poet.id, date) do
        nil ->
          conn
          |> put_status(404)
          |> json(%{error: "no entry for #{date_str}; call journal_upsert_entry first"})

        entry ->
          do_put_places(conn, poet, entry, places)
      end
    end)
  end

  def put_places(conn, _params) do
    conn |> put_status(422) |> json(%{error: "places (list) is required"})
  end

  defp do_put_places(conn, poet, entry, places) do
    if Topics.get_excursion_for_entry(entry.id) do
      # An excursion has no address to pin; its finds have their own call.
      conn
      |> put_status(422)
      |> json(%{
        error:
          "this entry is an excursion; it has no places to pin. " <>
            "Call journal_put_finds with what you brought back instead."
      })
    else
      do_replace_places(conn, poet, entry, places)
    end
  end

  defp do_replace_places(conn, poet, entry, places) do
    {kept, over_cap} = Enum.split(places, @max_places)
    {fresh, repeats} = reject_repeats(entry, kept)
    {usable, dropped} = reject_dead_links(fresh, "source_url")
    existing = Guide.list_places_for_entry(entry.id)

    if wipe_by_rejection?(kept, usable, existing) do
      reply = kept_existing_reply(:place, existing, dropped, over_cap)
      json(conn, Map.put(reply, :already_logged, repeats))
    else
      save_places(conn, poet, entry, usable, dropped, over_cap, repeats)
    end
  end

  # A place logged on an earlier day of this stay is not logged again, events
  # included, however it is spelled; nor twice in one list. Checked before the
  # links, so a repeat costs no network call.
  defp reject_repeats(entry, places) do
    seen = entry |> Guide.logged_earlier_in_stay() |> MapSet.new(&Guide.name_key(&1.name))

    {fresh, repeats, _seen} =
      Enum.reduce(places, {[], [], seen}, fn place, {fresh, repeats, seen} ->
        name = place["name"] || place[:name]
        key = Guide.name_key(name)

        cond do
          key == "" -> {[place | fresh], repeats, seen}
          MapSet.member?(seen, key) -> {fresh, [name | repeats], seen}
          true -> {[place | fresh], repeats, MapSet.put(seen, key)}
        end
      end)

    {Enum.reverse(fresh), Enum.reverse(repeats)}
  end

  defp save_places(conn, poet, entry, usable, dropped, over_cap, repeats) do
    case Guide.replace_places(entry, usable) do
      {:ok, saved} ->
        city = entry.place_name || poet.current_place_name
        {resolved, not_located} = Geocoding.resolve_within_budget(saved, city)
        Geocoding.drain_async(poet.id, city)

        json(conn, %{
          ok: true,
          place_count: length(resolved),
          place_ids: Map.new(resolved, &{&1.name, &1.id}),
          not_located: not_located,
          dropped: dropped,
          # already in this stay's guide from an earlier day; not saved again
          already_logged: repeats,
          over_cap: length(over_cap)
        })

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  @doc """
  Replaces the day's finds: what an excursion brought back. The twin of
  `put_places` for a day off the road, with the same forgiveness (a dead link
  drops that one find, named in the response) and no geocoding: a find is a
  URL, not an address. Only an excursion entry has finds.
  """
  def put_finds(conn, %{"date" => date_str, "finds" => finds} = params) when is_list(finds) do
    with_poet_and_date(conn, date_str, fn poet, date ->
      with %{} = entry <- Journal.get_entry(poet.id, date),
           %{} = excursion <- Topics.get_excursion_for_entry(entry.id) do
        do_put_finds(conn, entry, excursion, finds, params)
      else
        nil ->
          if Journal.get_entry(poet.id, date) do
            conn
            |> put_status(422)
            |> json(%{
              error:
                "this entry is not an excursion; it has places, not finds. " <>
                  "Call journal_put_places instead."
            })
          else
            conn
            |> put_status(404)
            |> json(%{error: "no entry for #{date_str}; call journal_upsert_entry first"})
          end
      end
    end)
  end

  def put_finds(conn, _params) do
    conn |> put_status(422) |> json(%{error: "finds (list) is required"})
  end

  defp do_put_finds(conn, entry, excursion, finds, params) do
    {kept, over_cap} = Enum.split(finds, @max_places)
    {usable, dropped} = reject_dead_links(kept, "url")
    existing = Topics.list_finds_for_entry(entry.id)

    if wipe_by_rejection?(kept, usable, existing) do
      {:ok, _} = Topics.set_venue(excursion, Map.take(params, ["venue_name", "venue_url"]))
      json(conn, kept_existing_reply(:find, existing, dropped, over_cap))
    else
      save_finds(conn, entry, excursion, usable, dropped, over_cap, params)
    end
  end

  # The list replaces the day's whole list, and a model retrying one dropped
  # item sends that item alone. Hilma, 2026-09-16: four finds saved, one
  # dropped, then the dropped one re-sent twice on its own; each retry wiped
  # the four and saved nothing. A call whose every item was rejected changes
  # nothing when the entry already has a list. An empty list sent on purpose
  # still clears it.
  defp wipe_by_rejection?(sent, usable, existing),
    do: sent != [] and usable == [] and existing != []

  defp kept_existing_reply(kind, existing, dropped, over_cap) do
    {count_key, ids_key, noun, tool} =
      case kind do
        :find -> {:find_count, :find_ids, "finds", "journal_put_finds"}
        :place -> {:place_count, :place_ids, "places", "journal_put_places"}
      end

    %{
      :ok => true,
      count_key => length(existing),
      ids_key => Map.new(existing, &{&1.name, &1.id}),
      :dropped => dropped,
      :over_cap => length(over_cap),
      :kept_existing => true,
      :note =>
        "Every item in this call was dropped or already logged, so nothing changed: your #{length(existing)} " <>
          "#{noun} already saved are kept. A dropped item is gone; do not re-send it alone. " <>
          "#{tool} replaces the whole list, so any later call must carry all of them."
    }
  end

  defp save_finds(conn, entry, excursion, usable, dropped, over_cap, params) do
    with {:ok, saved} <- Topics.replace_finds(entry, usable),
         {:ok, _} <- Topics.set_venue(excursion, Map.take(params, ["venue_name", "venue_url"])) do
      json(conn, %{
        ok: true,
        find_count: length(saved),
        find_ids: Map.new(saved, &{&1.name, &1.id}),
        dropped: dropped,
        over_cap: length(over_cap)
      })
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(422) |> json(%{error: changeset_errors(changeset)})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  # Concurrent on purpose: see @link_check_concurrency. A check that times out
  # counts as a pass -- this is a liveness nicety, and it must never be the
  # reason a real recommendation is lost. `url_key` names the field that
  # carries the link ("source_url" on a place, "url" on a find).
  defp reject_dead_links(items, url_key) do
    items
    |> Task.async_stream(&check_item_link(&1, url_key),
      max_concurrency: @link_check_concurrency,
      timeout: 8_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(items)
    |> Enum.reduce({[], []}, fn
      {{:ok, :ok}, item}, {keep, drop} -> {[item | keep], drop}
      {{:ok, {:dead, name}}, _item}, {keep, drop} -> {keep, [name | drop]}
      {{:exit, _}, item}, {keep, drop} -> {[item | keep], drop}
    end)
    |> then(fn {keep, drop} -> {Enum.reverse(keep), Enum.reverse(drop)} end)
  end

  defp check_item_link(item, url_key) do
    url = item[url_key] || item[String.to_existing_atom(url_key)]

    if is_binary(url) and url != "" and LinkCheck.check(url) != :ok do
      {:dead, item["name"] || item[:name]}
    else
      :ok
    end
  end

  @doc """
  Reads an entry back: sections, media, and the feedback markers on it.

  The agent's only way to see its own prose in a fresh session. A revision
  must start from what is actually on the page, and `put_sections` replaces
  the whole list, so rewriting from memory would quietly drop sections.
  """
  def show(conn, %{"date" => date_str}) do
    with_poet_and_date(conn, date_str, fn poet, date ->
      case Journal.get_entry_preloaded(poet.id, date) do
        nil ->
          conn |> put_status(404) |> json(%{error: "no entry for #{date_str}"})

        entry ->
          sections = entry.sections

          media =
            sections
            |> Enum.map(& &1.media_id)
            |> Enum.reject(&is_nil/1)
            |> Enum.map(&Journal.get_media/1)
            |> Enum.reject(&is_nil/1)
            |> Kernel.++(Journal.unattached_illustrations(entry, sections))
            |> Kernel.++(Journal.spot_media(entry))
            |> Enum.uniq_by(& &1.id)
            |> Enum.map(fn m ->
              base = %{id: m.id, kind: m.kind, alt_text: m.alt_text}

              if m.kind == "spot",
                do: Map.put(base, :markdown, Journal.spot_markdown(m)),
                else: base
            end)

          markers =
            entry.id
            |> Markers.list_markers()
            |> Markers.payload()
            |> Enum.map(fn m ->
              spec = Marker.spec(m.kind) || %{meaning: nil, ask: nil}
              Map.merge(m, %{meaning: spec.meaning, ask: spec.ask})
            end)

          json(conn, %{
            entry: %{
              entry_date: entry.entry_date,
              journey_day: Journal.journey_day(entry),
              title: entry.title,
              teaser: entry.teaser,
              place_name: entry.place_name,
              status: entry.status,
              published_at: entry.published_at,
              weather: entry.weather,
              sources: entry.sources
            },
            sections:
              Enum.map(sections, fn s ->
                %{
                  position: s.position,
                  kind: s.kind,
                  title: s.title,
                  body: s.body,
                  media_id: s.media_id,
                  metadata: s.metadata
                }
              end),
            media: media,
            markers: markers
          })
      end
    end)
  end

  def publish(conn, %{"date" => date_str}) do
    with_poet_and_date(conn, date_str, fn poet, date ->
      case Journal.get_entry(poet.id, date) do
        nil ->
          conn |> put_status(404) |> json(%{error: "no entry for #{date_str}"})

        entry ->
          case Journal.publish_entry(entry) do
            {:ok, published} ->
              json(conn, %{ok: true, published_at: published.published_at})

            {:error, changeset} ->
              conn |> put_status(422) |> json(%{error: changeset_errors(changeset)})
          end
      end
    end)
  end

  defp with_poet_and_date(conn, date_str, fun) do
    user = conn.assigns.agent_user

    with {:ok, date} <- Date.from_iso8601(to_string(date_str)),
         %Poets.Poet{} = poet <- Poets.get_poet_by_user(user.id) do
      fun.(poet, date)
    else
      {:error, _} ->
        conn |> put_status(422) |> json(%{error: "invalid date, expected YYYY-MM-DD"})

      nil ->
        conn |> put_status(404) |> json(%{error: "no poet configured"})
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
