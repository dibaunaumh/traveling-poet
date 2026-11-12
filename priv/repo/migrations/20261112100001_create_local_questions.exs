defmodule TravelingPoet.Repo.Migrations.CreateLocalQuestions do
  use Ecto.Migration

  # Local voices (card-10, dec-020): a reader who lives in a city a public
  # poet is visiting may be asked for tips, if they said yes when giving
  # their home. Off by default; credit is anonymous unless they choose.
  def change do
    alter table(:users) do
      add :local_voice, :boolean, default: false, null: false
      add :local_voice_credit, :string, default: "anonymous", null: false
    end

    create table(:local_questions) do
      # the visiting poet, and the local reader asked
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :place_name, :string, null: false
      add :status, :string, null: false, default: "open"
      add :answer, :text
      add :answered_at, :utc_datetime
      # the page the poet put the tip on
      add :used_entry_id, references(:journal_entries, on_delete: :nilify_all)

      timestamps()
    end

    create index(:local_questions, [:poet_id])
    create index(:local_questions, [:user_id])
  end
end
