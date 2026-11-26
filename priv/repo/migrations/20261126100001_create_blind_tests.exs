defmodule TravelingPoet.Repo.Migrations.CreateBlindTests do
  use Ecto.Migration

  # A blind writing test judged in the admin pages (dec-024's grading): the
  # eval manifest as `mix tpoet.eval_writing` writes it, and the judge's
  # votes, kept on the server so a test can be judged from a phone.
  def change do
    create table(:blind_tests) do
      add :name, :string, null: false
      add :title, :string
      add :manifest, :map, null: false
      add :votes, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:blind_tests, [:name])
  end
end
