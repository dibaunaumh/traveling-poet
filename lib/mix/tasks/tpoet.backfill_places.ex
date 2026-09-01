defmodule Mix.Tasks.Tpoet.BackfillPlaces do
  @shortdoc "Extracts trip-guide places from already-published journal entries"

  @moduledoc """
  One-off backfill: re-reads published entries and pulls out the places they
  recommend, so trips that predate the trip guide are not left empty.

      mix tpoet.backfill_places                        # DRY RUN, 25 entries
      mix tpoet.backfill_places --poet 3               # one poet only
      mix tpoet.backfill_places --poet 3 --commit      # actually write
      mix tpoet.backfill_places --commit --limit 200 --no-geocode

  Dry run is the DEFAULT. It still calls the model -- that is the part worth
  previewing -- and prints what it would write without touching the database.
  Read one poet's output before widening.

  Options:

      --commit         write the extracted places (otherwise print only)
      --poet ID        restrict to one poet
      --limit N        entries to process (default 25)
      --force          re-extract entries that already have places
      --no-geocode     leave places pending for the background drainer
      --geocode-delay-ms N   pause between lookups (default 1500)

  Requires OPENROUTER_API_KEY. Geocoding a few hundred addresses is bulk use by
  Nominatim's standards -- run it off-peak, and leave the delay alone unless
  you have a reason.
  """

  use Mix.Task

  import Ecto.Query

  alias TravelingPoet.{Guide, Journal, Repo}
  alias TravelingPoet.Guide.{Extractor, Geocoding}
  alias TravelingPoet.Journal.Entry

  @switches [
    commit: :boolean,
    poet: :integer,
    limit: :integer,
    force: :boolean,
    no_geocode: :boolean,
    geocode_delay_ms: :integer
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    unless Extractor.configured?() do
      Mix.raise("OPENROUTER_API_KEY is not set — extraction needs it.")
    end

    commit? = Keyword.get(opts, :commit, false)
    entries = candidates(opts)

    Mix.shell().info(
      "#{if commit?, do: "COMMIT", else: "DRY RUN"}: #{length(entries)} entr#{if length(entries) == 1, do: "y", else: "ies"}, model #{Extractor.model()}\n"
    )

    totals = Enum.reduce(entries, %{places: 0, skipped: 0, failed: 0}, &process(&1, &2, opts))

    Mix.shell().info("""

    Done. #{totals.places} places #{if commit?, do: "written", else: "found"}, \
    #{totals.skipped} entries skipped, #{totals.failed} failed.\
    #{unless commit?, do: "\nNothing was written — re-run with --commit.", else: ""}
    """)
  end

  defp candidates(opts) do
    Entry
    |> where(status: "published")
    |> maybe_poet(opts[:poet])
    |> order_by(desc: :entry_date)
    |> limit(^Keyword.get(opts, :limit, 25))
    |> Repo.all()
    |> Enum.map(&Journal.preload_entry/1)
  end

  defp maybe_poet(query, nil), do: query
  defp maybe_poet(query, poet_id), do: where(query, poet_id: ^poet_id)

  defp process(entry, totals, opts) do
    cond do
      not Keyword.get(opts, :force, false) and Guide.list_places_for_entry(entry.id) != [] ->
        Mix.shell().info(
          "· #{entry.entry_date} #{entry.place_name} — already has places, skipping"
        )

        Map.update!(totals, :skipped, &(&1 + 1))

      true ->
        extract_one(entry, totals, opts)
    end
  end

  defp extract_one(entry, totals, opts) do
    case Extractor.extract(entry, entry.sections) do
      {:ok, []} ->
        Mix.shell().info("· #{entry.entry_date} #{entry.place_name} — nothing specific named")
        Map.update!(totals, :skipped, &(&1 + 1))

      {:ok, places} ->
        report(entry, places)
        if Keyword.get(opts, :commit, false), do: write(entry, places, opts)
        Map.update!(totals, :places, &(&1 + length(places)))

      {:error, reason} ->
        # A malformed or failed extraction skips the entry. It must never take
        # the rest of the run down with it.
        Mix.shell().error(
          "· #{entry.entry_date} #{entry.place_name} — FAILED: #{inspect(reason)}"
        )

        Map.update!(totals, :failed, &(&1 + 1))
    end
  end

  defp report(entry, places) do
    Mix.shell().info("· #{entry.entry_date} #{entry.place_name} — #{length(places)}:")

    Enum.each(places, fn p ->
      Mix.shell().info("    #{p["name"]} (#{p["category"]})#{address_note(p["address"])}")
    end)
  end

  defp address_note(nil), do: "  [no address — will not get a pin]"
  defp address_note(address), do: "  #{address}"

  defp write(entry, places, opts) do
    case Guide.replace_places(entry, places) do
      {:ok, saved} ->
        unless Keyword.get(opts, :no_geocode, false), do: geocode(saved, entry, opts)

      {:error, reason} ->
        Mix.shell().error("    write failed: #{inspect(reason)}")
    end
  end

  defp geocode(places, entry, opts) do
    delay = Keyword.get(opts, :geocode_delay_ms, 1500)

    Enum.each(places, fn place ->
      Geocoding.resolve(place, entry.place_name)
      Process.sleep(delay)
    end)
  end
end
