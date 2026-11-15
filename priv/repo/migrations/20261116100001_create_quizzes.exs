defmodule TravelingPoet.Repo.Migrations.CreateQuizzes do
  use Ecto.Migration

  # Quiz day (card-140, dec-021): every few weeks the poet spends a day
  # quizzing its reader on the curious facts of past pages instead of
  # writing a new one. The quiz is a side table of the day's entry, like an
  # excursion; the reader's answers are private to them.
  def change do
    create table(:quizzes) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      # queued (the day is held for a quiz), written, published
      add :status, :string, null: false, default: "queued"
      add :scheduled_for, :date, null: false
      # "cadence" or "admin"
      add :source, :string, null: false, default: "cadence"
      add :journal_entry_id, references(:journal_entries, on_delete: :delete_all)
      # the poet's closing notes by score tier: %{"high", "mid", "low"}
      add :notes, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:quizzes, [:poet_id, :scheduled_for])
    create unique_index(:quizzes, [:journal_entry_id])

    create table(:quiz_questions) do
      add :quiz_id, references(:quizzes, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      # choice | fib | drawing | first
      add :kind, :string, null: false
      add :prompt, :text, null: false
      # [%{"id", "text", "source_key", "source_entry_id"}]
      add :options, {:array, :map}, null: false, default: "[]"
      add :answer_id, :string, null: false
      add :aside, :text
      # where the fact was written, for "read it again"
      add :source_entry_id, references(:journal_entries, on_delete: :nilify_all)
      add :source_key, :string
      add :media_id, references(:media, on_delete: :nilify_all)

      timestamps()
    end

    create index(:quiz_questions, [:quiz_id])

    create table(:quiz_answers) do
      add :question_id, references(:quiz_questions, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :option_id, :string, null: false
      add :correct, :boolean, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:quiz_answers, [:question_id, :user_id])
    create index(:quiz_answers, [:user_id])
  end
end
