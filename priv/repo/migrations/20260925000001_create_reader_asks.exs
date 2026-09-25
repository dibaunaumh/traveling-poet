defmodule TravelingPoet.Repo.Migrations.CreateReaderAsks do
  use Ecto.Migration

  def change do
    create table(:reader_asks) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :about, :string, null: false, default: "topics"
      add :reason, :string
      add :question, :text, null: false
      add :status, :string, null: false, default: "open"
      add :chat_message_id, references(:chat_messages, on_delete: :nilify_all)
      add :replied_at, :utc_datetime
      add :answered_at, :utc_datetime
      timestamps()
    end

    create index(:reader_asks, [:poet_id, :inserted_at])
    create index(:reader_asks, [:user_id, :status])
  end
end
