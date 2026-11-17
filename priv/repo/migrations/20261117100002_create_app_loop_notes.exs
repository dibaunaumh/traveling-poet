defmodule TravelingPoet.Repo.Migrations.CreateAppLoopNotes do
  use Ecto.Migration

  # The app-side poet's notebook (dec-024, option D): what the poet chose to
  # carry from one run to the next with its `remember` tool. A sprite poet's
  # memory is its one long OpenClaw conversation; an app-side run starts
  # fresh, so what it keeps lives here and comes back in every run's memory
  # block (`AppLoop.Memory`). A forgotten note is kept, marked.
  def change do
    create table(:app_loop_notes) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      # the day of the run that wrote it
      add :entry_date, :date, null: false
      add :body, :text, null: false
      add :forgotten_on, :date

      timestamps(type: :utc_datetime)
    end

    create index(:app_loop_notes, [:poet_id, :entry_date])

    # the memory block a run started from, so the grading can see it
    alter table(:app_loop_runs) do
      add :memory, :text
    end
  end
end
