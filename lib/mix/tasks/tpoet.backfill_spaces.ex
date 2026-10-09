defmodule Mix.Tasks.Tpoet.BackfillSpaces do
  @shortdoc "Resolves existing places, finds, stay areas and stays to shared items"

  @moduledoc """
  One-off backfill for the Spaces model (kb-002, phase 0): points every
  place, find, stay area and path point at the item it is a visit of,
  creating the items as it goes.

      mix tpoet.backfill_spaces                  # DRY RUN: resolves, reports, rolls back
      mix tpoet.backfill_spaces --poet 3         # one poet only
      mix tpoet.backfill_spaces --commit         # keep it
      mix tpoet.backfill_spaces --commit --force # re-resolve rows already linked

  A formatter around `TravelingPoet.Spaces.Backfill.run/1`; in production
  call that over `rpc`. No model call and no geocoding: resolution is by
  name and pin only.
  """

  use Mix.Task

  alias TravelingPoet.Spaces.Backfill

  @switches [commit: :boolean, poet: :integer, force: :boolean]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    report =
      Backfill.run(
        commit: Keyword.get(opts, :commit, false),
        poet_id: opts[:poet],
        force: Keyword.get(opts, :force, false)
      )

    Mix.shell().info(if report.committed, do: "COMMIT", else: "DRY RUN")

    Mix.shell().info("""
    linked: #{report.linked.stays} stays, #{report.linked.places} places, \
    #{report.linked.finds} finds, #{report.linked.areas} areas
    items created: #{report.items_created}
    by kind: #{inspect(report.by_kind)}
    shared by more than one poet: #{report.shared}
    reviews written: #{report.reviews}
    """)

    Enum.each(report.samples, fn s ->
      Mix.shell().info(
        "  · #{s.name} (#{s.kind}#{if s.city, do: ", " <> s.city}) — #{s.poets} poets"
      )
    end)

    unless report.committed,
      do: Mix.shell().info("\nNothing was written — re-run with --commit.")
  end
end
