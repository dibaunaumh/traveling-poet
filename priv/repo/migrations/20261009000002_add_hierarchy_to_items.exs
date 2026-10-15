defmodule TravelingPoet.Repo.Migrations.AddHierarchyToItems do
  use Ecto.Migration

  def change do
    alter table(:items) do
      # ISO 3166-1 alpha-2, carried down from the country item at the top of
      # the admin hierarchy, so "textile places in 9 countries" is one query.
      add :country_code, :string
    end

    create index(:items, [:country_code])

    # The fourth reference system of the travel deployment (kb-002 phase 1):
    # country > region > city, items with a parent, near = a shared ancestor.
    execute(
      "INSERT OR IGNORE INTO reference_systems (key, name, type, config, inserted_at, updated_at) " <>
        "VALUES ('admin', 'Country, region, city', 'hierarchy', '{}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
      "DELETE FROM reference_systems WHERE key = 'admin'"
    )
  end
end
