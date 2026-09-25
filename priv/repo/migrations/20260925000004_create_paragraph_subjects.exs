defmodule TravelingPoet.Repo.Migrations.CreateParagraphSubjects do
  use Ecto.Migration

  def change do
    create table(:paragraph_subjects) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :journal_entry_id, references(:journal_entries, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :section_kind, :string
      add :excerpt, :string
      add :topic, :string
      add :second_topic, :string
      add :classified_at, :utc_datetime, null: false
      timestamps()
    end

    create unique_index(:paragraph_subjects, [:journal_entry_id, :key])
    create index(:paragraph_subjects, [:key])
  end
end
