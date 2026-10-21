defmodule TravelingPoet.Repo.Migrations.CreateGooglePlaceIds do
  use Ecto.Migration

  def change do
    # Google's place id for a place the poets wrote about (dec-012), so a
    # "Save to Google Maps" link can carry it. Keyed by name and where, not by
    # place row: places are re-inserted on every re-put, bookmarks are
    # snapshots, and two poets at one cafe share the lookup.
    create table(:google_place_ids) do
      add :key, :string, null: false
      # nil when Google found nothing there (looked up again later)
      add :place_id, :string
      timestamps()
    end

    create unique_index(:google_place_ids, [:key])
  end
end
