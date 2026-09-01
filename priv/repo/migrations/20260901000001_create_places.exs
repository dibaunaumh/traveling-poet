defmodule TravelingPoet.Repo.Migrations.CreatePlaces do
  use Ecto.Migration

  # Places live in their own table, NOT as a journal_section kind, for the same
  # reason entry_prompts do (see 20260831000001): replace_sections/2 wipes
  # sections wholesale, and travel-and-journal/SKILL.md explicitly tells the
  # poet to re-send its full section list after illustrating. A place riding
  # along in that list would lose its geocoded coordinates and its drawing on
  # every re-put -- both of which cost real money to produce.
  def change do
    create table(:places) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :journal_entry_id, references(:journal_entries, on_delete: :delete_all), null: false
      # The stay this place belongs to. Denormalized at write time rather than
      # derived from a date range, so the Guide is a plain query and a poet who
      # revisits a city gets two distinct guides instead of one merged one.
      add :path_point_id, references(:path_points, on_delete: :nilify_all)
      # Denormalized from the entry. Safe: upsert_entry/3 drops :entry_date on
      # update, so an entry can never change date.
      add :entry_date, :date, null: false

      add :name, :string, null: false
      add :category, :string, null: false
      add :blurb, :text
      add :address, :string

      # Filled in by the geocoder, which is allowed to fail. A place with no
      # coordinates still belongs in the List and Itinerary views.
      add :lat, :float
      add :lng, :float
      add :geocode_status, :string, null: false, default: "pending"

      # The POET's own 1-5 take, never a sourced review score. The name is
      # load-bearing: the UI renders it attributed ("Wren's pick"), and a field
      # called `rating` invites exactly the misreading we are avoiding.
      # Backfilled places leave this nil -- inferring a rating from prose the
      # poet wrote is fabrication, not extraction.
      add :poet_rating, :integer

      add :source_url, :string
      # A real FK, unlike journal_sections.media_id: we control creation order
      # here, and ecto_sqlite3 enforces FKs, so a deleted drawing must nilify
      # rather than orphan.
      add :media_id, references(:media, on_delete: :nilify_all)
      add :position, :integer, null: false, default: 0
      add :source, :string, null: false, default: "agent"

      timestamps()
    end

    create index(:places, [:poet_id, :entry_date])
    create index(:places, [:poet_id, :path_point_id])
    create index(:places, [:journal_entry_id, :position])
    create index(:places, [:geocode_status])

    # What makes the agent write path idempotent, the same way
    # [:poet_id, :entry_date] does for journal_entries.
    create unique_index(:places, [:journal_entry_id, :name])
  end
end
