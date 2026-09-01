defmodule TravelingPoetWeb.Api.JournalApiController do
  use TravelingPoetWeb, :controller

  require Logger

  alias TravelingPoet.{Guide, Journal, LinkCheck, Poets, Preferences}
  alias TravelingPoet.Guide.Geocoding

  # A day's finds, not a directory. The skill asks for 2-4; this is the
  # backstop against a model that decides to list everything it walked past.
  @max_places 8
  # Link checks probe live URLs with a 6s timeout each (LinkCheck), so a
  # full list run serially could hold the agent's request open for most of a
  # minute.
  @link_check_concurrency 6

  def upsert_entry(conn, %{"entry_date" => date_str} = params) do
    with_poet_and_date(conn, date_str, fn poet, date ->
      attrs =
        params
        |> Map.take(["title", "place_name", "lat", "lng", "weather", "sources"])
        |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)

      case Journal.upsert_entry(poet.id, date, attrs) do
        {:ok, entry} ->
          prompt = maybe_attach_prompt(entry, params["prompt"])

          json(conn, %{
            ok: true,
            entry_id: entry.id,
            entry_date: entry.entry_date,
            status: entry.status,
            prompt_accepted: prompt
          })

        {:error, changeset} ->
          conn |> put_status(422) |> json(%{error: changeset_errors(changeset)})
      end
    end)
  end

  def upsert_entry(conn, _params) do
    conn |> put_status(422) |> json(%{error: "entry_date (YYYY-MM-DD) is required"})
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
    case Journal.get_entry(poet.id, date) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{error: "no entry for #{date_str}; call journal_upsert_entry first"})

      entry ->
        case Journal.replace_sections(entry, sections) do
          {:ok, saved} ->
            json(conn, %{ok: true, section_count: length(saved)})

          {:error, reason} ->
            conn |> put_status(422) |> json(%{error: inspect(reason)})
        end
    end
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
    {kept, over_cap} = Enum.split(places, @max_places)
    {usable, dropped} = reject_dead_links(kept)

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
          over_cap: length(over_cap)
        })

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  # Concurrent on purpose: see @link_check_concurrency. A check that times out
  # counts as a pass -- this is a liveness nicety, and it must never be the
  # reason a real recommendation is lost.
  defp reject_dead_links(places) do
    places
    |> Task.async_stream(&check_place_link/1,
      max_concurrency: @link_check_concurrency,
      timeout: 8_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(places)
    |> Enum.reduce({[], []}, fn
      {{:ok, :ok}, place}, {keep, drop} -> {[place | keep], drop}
      {{:ok, {:dead, name}}, _place}, {keep, drop} -> {keep, [name | drop]}
      {{:exit, _}, place}, {keep, drop} -> {[place | keep], drop}
    end)
    |> then(fn {keep, drop} -> {Enum.reverse(keep), Enum.reverse(drop)} end)
  end

  defp check_place_link(place) do
    url = place["source_url"] || place[:source_url]

    if is_binary(url) and url != "" and LinkCheck.check(url) != :ok do
      {:dead, place["name"] || place[:name]}
    else
      :ok
    end
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
