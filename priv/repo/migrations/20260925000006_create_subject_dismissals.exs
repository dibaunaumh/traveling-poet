defmodule TravelingPoet.Repo.Migrations.CreateSubjectDismissals do
  use Ecto.Migration

  def change do
    create table(:subject_dismissals) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :path, :string, null: false
      timestamps()
    end

    create unique_index(:subject_dismissals, [:user_id, :path])
  end
end
