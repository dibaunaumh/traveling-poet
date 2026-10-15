defmodule TravelingPoet.Repo.Migrations.AddDurationToMedia do
  use Ecto.Migration

  def change do
    alter table(:media) do
      # Narration (card-122): how long the audio runs, so a page or an email
      # can say "5 min" without opening the file.
      add :duration_seconds, :integer
    end
  end
end
