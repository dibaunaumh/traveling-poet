defmodule Mix.Tasks.Tpoet.BackfillPlaces do
  @shortdoc "Extracts trip-guide places from already-published journal entries"

  @moduledoc """
  One-off backfill: re-reads published entries and pulls out the places they
  recommend, so trips that predate the trip guide are not left empty.

      mix tpoet.backfill_places                    # DRY RUN, 25 entries
      mix tpoet.backfill_places --poet 3           # one poet only
      mix tpoet.backfill_places --poet 3 --commit  # actually write
      mix tpoet.backfill_places --commit --limit 200 --no-geocode

  Dry run is the DEFAULT. It still calls the model -- that is the part worth
  previewing -- and prints what it would write without touching the database.
  Read one poet's output before widening.

  This is a formatter around `TravelingPoet.Guide.Backfill.run/1`. In
  production, where there is no Mix, call that module directly:

      bin/traveling_poet rpc 'TravelingPoet.Guide.Backfill.run(poet_id: 3)'

  Requires OPENROUTER_API_KEY. Pacing is handled by Geocoder.Limiter, which
  already holds the whole app to Nominatim's 1 req/s.
  """

  use Mix.Task

  alias TravelingPoet.Guide.{Backfill, Extractor}

  @switches [
    commit: :boolean,
    poet: :integer,
    limit: :integer,
    force: :boolean,
    geocode: :boolean
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    unless Extractor.configured?() do
      Mix.raise("OPENROUTER_API_KEY is not set — extraction needs it.")
    end

    commit? = Keyword.get(opts, :commit, false)

    %{entries: entries, totals: totals} =
      Backfill.run(
        poet_id: opts[:poet],
        limit: opts[:limit],
        commit: commit?,
        force: Keyword.get(opts, :force, false),
        geocode: Keyword.get(opts, :geocode, true)
      )

    Mix.shell().info(
      "#{if commit?, do: "COMMIT", else: "DRY RUN"} · model #{Extractor.model()}\n"
    )

    Enum.each(entries, &report/1)

    Mix.shell().info("""

    #{totals.places} places across #{totals.entries} entries \
    (#{totals.skipped} skipped, #{totals.failed} failed).\
    #{unless commit?, do: "\nNothing was written — re-run with --commit.", else: ""}
    """)
  end

  defp report(%{status: {:failed, reason}} = e),
    do: Mix.shell().error("· #{e.date} #{e.city} — FAILED: #{inspect(reason)}")

  defp report(%{status: :skipped_has_places} = e),
    do: Mix.shell().info("· #{e.date} #{e.city} — already has places, skipping")

  defp report(%{status: :nothing_named} = e),
    do: Mix.shell().info("· #{e.date} #{e.city} — nothing specific named")

  defp report(e) do
    Mix.shell().info("· #{e.date} #{e.city} — #{length(e.places)}:")

    Enum.each(e.places, fn {name, category, address} ->
      Mix.shell().info("    #{name} (#{category})#{address_note(address)}")
    end)
  end

  defp address_note(nil), do: "  [no address — will not get a pin]"
  defp address_note(address), do: "  #{address}"
end
