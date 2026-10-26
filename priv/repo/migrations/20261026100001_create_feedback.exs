defmodule TravelingPoet.Repo.Migrations.CreateFeedback do
  use Ecto.Migration

  def change do
    # What readers tell us about the app itself (card-137): something broken,
    # something to change, something missing. A visitor who is not signed in
    # can write too (card-63), so user_id may be empty and email stands in.
    create table(:feedback_messages) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :email, :string
      add :kind, :string, null: false
      add :body, :text, null: false
      add :page, :string
      add :client, :string
      add :status, :string, null: false, default: "new"
      timestamps()
    end

    create index(:feedback_messages, [:user_id])
    create index(:feedback_messages, [:status])
    create index(:feedback_messages, [:email])

    # The "would you recommend us" question asked under a fresh page
    create table(:nps_responses) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :score, :integer, null: false
      add :comment, :text
      add :journal_entry_id, references(:journal_entries, on_delete: :nilify_all)
      timestamps()
    end

    create index(:nps_responses, [:user_id])

    alter table(:users) do
      add :nps_prompt_dismissed_at, :utc_datetime
    end
  end
end
