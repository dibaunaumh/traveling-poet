defmodule TravelingPoet.Journal.MediaRepair do
  @moduledoc """
  Links the drawings that were made before their page existed.

  Until 2026-10-20 a drawing sent with an `entry_date` that had no entry row
  yet (the poet draws first, then writes) was stored with no entry, and a
  page shows only drawings linked to it: the main drawing and both spots of
  Nam's page that day were missing, and 56 spot drawings across the fleet
  had gone the same way since late September. `Journal.ensure_entry/2` now
  creates the row at draw time and `replace_sections/2` links what a body
  embeds; this repairs the pages written before that.

  A drawing is linked to the one entry of its poet, within a day of when it
  was drawn, whose sections carry it (as a section's `media_id` or as
  `![alt](/media/:id)` in a body). A drawing no page mentions stays as it
  is; so does one a place or find owns. Dry run unless `commit: true`.

      TravelingPoet.Journal.MediaRepair.run(commit: true)
  """

  import Ecto.Query

  alias TravelingPoet.Journal.{Entry, Media, Section, Spots}
  alias TravelingPoet.Repo

  @spec run(keyword) :: %{
          linked: [{integer, integer}],
          unreferenced: [integer],
          committed: boolean
        }
  def run(opts \\ []) do
    commit? = Keyword.get(opts, :commit, false)
    since = Keyword.get(opts, :since, ~N[2026-09-01 00:00:00])

    orphans =
      Repo.all(
        from(m in Media,
          where: is_nil(m.journal_entry_id) and m.kind in ["illustration", "spot"],
          where: m.inserted_at >= ^since,
          where:
            m.id not in subquery(
              from(p in TravelingPoet.Guide.Place,
                where: not is_nil(p.media_id),
                select: p.media_id
              )
            ),
          where:
            m.id not in subquery(
              from(f in TravelingPoet.Topics.Find,
                where: not is_nil(f.media_id),
                select: f.media_id
              )
            ),
          order_by: m.id
        )
      )

    {linked, unreferenced} =
      Enum.reduce(orphans, {[], []}, fn media, {linked, unreferenced} ->
        case page_for(media) do
          nil -> {linked, [media.id | unreferenced]}
          entry -> {[{media.id, entry.id} | linked], unreferenced}
        end
      end)

    linked = Enum.reverse(linked)

    if commit? do
      Enum.each(linked, fn {media_id, entry_id} ->
        Repo.update_all(from(m in Media, where: m.id == ^media_id and is_nil(m.journal_entry_id)),
          set: [journal_entry_id: entry_id]
        )
      end)
    end

    %{linked: linked, unreferenced: Enum.reverse(unreferenced), committed: commit?}
  end

  defp page_for(%Media{} = media) do
    day = NaiveDateTime.to_date(media.inserted_at)

    Repo.all(
      from(e in Entry,
        where: e.poet_id == ^media.poet_id,
        where: e.entry_date >= ^Date.add(day, -1) and e.entry_date <= ^Date.add(day, 1),
        order_by: e.entry_date,
        preload: [sections: ^from(s in Section, order_by: s.position)]
      )
    )
    |> Enum.find(fn entry ->
      Enum.any?(entry.sections, &(&1.media_id == media.id)) or
        MapSet.member?(Spots.referenced_ids(entry.sections), media.id)
    end)
  end
end
