defmodule TravelingPoet.Repo.Migrations.CreateBookmarks do
  use Ecto.Migration

  def change do
    create table(:bookmarks) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :poet_id, references(:poets, on_delete: :nilify_all)
      add :journal_entry_id, references(:journal_entries, on_delete: :nilify_all)
      add :name, :string, null: false
      add :snapshot, :map, null: false, default: %{}
      timestamps()
    end

    create unique_index(:bookmarks, [:user_id, :kind, :journal_entry_id, :name])
    create index(:bookmarks, [:user_id])
  end
end
