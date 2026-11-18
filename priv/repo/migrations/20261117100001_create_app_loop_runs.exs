defmodule TravelingPoet.Repo.Migrations.CreateAppLoopRuns do
  use Ecto.Migration

  # One shadow run of the app-side poet loop (dec-024): what it wrote for a
  # day a sprite poet already published, and how the run went. Never shown
  # to a reader; read over rpc and by the grading.
  def change do
    create table(:app_loop_runs) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :entry_date, :date, null: false
      add :mode, :string, null: false, default: "shadow"
      add :model, :string
      add :status, :string, null: false
      add :error, :text
      add :page, :map
      add :steps, :map
      add :model_calls, :integer, default: 0
      add :tool_calls, :integer, default: 0
      add :malformed_calls, :integer, default: 0
      add :tool_errors, :integer, default: 0
      add :tokens_in, :integer, default: 0
      add :tokens_out, :integer, default: 0
      add :cost, :float
      add :ms, :integer
      add :final_text, :text
      add :trigger, :text

      timestamps(type: :utc_datetime)
    end

    create index(:app_loop_runs, [:poet_id, :entry_date])
  end
end
