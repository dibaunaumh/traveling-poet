defmodule TravelingPoet.Repo.Migrations.CreateReaderNotes do
  use Ecto.Migration

  def change do
    # "About you" (card-125, dec-011): one plain note about the reader, the
    # poet's draft until the reader saves it, theirs after that
    create table(:reader_notes) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :text, :text, null: false
      add :written_by, :string, null: false, default: "poet"
      add :understood, :map, null: false, default: %{}
      add :understood_at, :utc_datetime
      timestamps()
    end

    create unique_index(:reader_notes, [:poet_id])

    # A line the poet suggests adding to the note, or taking out of it
    create table(:reader_note_suggestions) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :text, :text, null: false
      add :reason, :text
      add :status, :string, null: false, default: "pending"
      timestamps()
    end

    create index(:reader_note_suggestions, [:poet_id, :status])
  end
end
