defmodule TravelingPoet.Repo.Migrations.CreateParagraphReads do
  use Ecto.Migration

  def change do
    create table(:paragraph_reads) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :journal_entry_id, references(:journal_entries, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :read_on, :date, null: false
      add :ms, :integer, null: false, default: 0
      add :chars, :integer, null: false
      timestamps()
    end

    create unique_index(:paragraph_reads, [:user_id, :journal_entry_id, :key, :read_on])
    create index(:paragraph_reads, [:user_id, :read_on])

    alter table(:users) do
      add :reading_signals, :boolean, null: false, default: true
    end
  end
end
