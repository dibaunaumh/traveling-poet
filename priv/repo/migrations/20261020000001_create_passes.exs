defmodule TravelingPoet.Repo.Migrations.CreatePasses do
  use Ecto.Migration

  def change do
    # A place or find the reader marked "Not for me" (card-123), keyed like a
    # bookmark so it survives the poet re-putting the page
    create table(:passes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :poet_id, references(:poets, on_delete: :nilify_all)
      add :journal_entry_id, references(:journal_entries, on_delete: :nilify_all)
      add :name, :string, null: false
      add :category, :string
      add :topic, :string
      add :second_topic, :string
      timestamps()
    end

    create unique_index(:passes, [:user_id, :kind, :journal_entry_id, :name])
    create index(:passes, [:user_id])
  end
end
