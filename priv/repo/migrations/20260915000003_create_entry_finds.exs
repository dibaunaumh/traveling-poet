defmodule TravelingPoet.Repo.Migrations.CreateEntryFinds do
  use Ecto.Migration

  # What an excursion brings back: a talk, a paper, a product, a session. A
  # find has a URL where a place has an address; nothing here is geocoded and
  # nothing reaches the trip guide. Its own table for the same reason places
  # have one: replace_sections wipes sections wholesale on every re-put.
  def change do
    create table(:entry_finds) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :journal_entry_id, references(:journal_entries, on_delete: :delete_all), null: false
      add :entry_date, :date, null: false
      add :name, :string, null: false
      add :url, :string, null: false
      add :kind, :string, null: false, default: "other"
      add :blurb, :text
      add :poet_rating, :integer
      add :media_id, references(:media, on_delete: :nilify_all)
      add :position, :integer, null: false, default: 0
      add :source, :string, null: false, default: "agent"
      timestamps()
    end

    create index(:entry_finds, [:poet_id, :entry_date])
    create index(:entry_finds, [:journal_entry_id, :position])
    create unique_index(:entry_finds, [:journal_entry_id, :name])
  end
end
