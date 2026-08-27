defmodule TravelingPoet.Repo.Migrations.AddMediaContentHash do
  use Ecto.Migration

  def change do
    alter table(:media) do
      # MD5 hex of the stored bytes — dedupe guard: an agent once re-uploaded
      # an old drawing as a "new" illustration when generation failed
      add :content_hash, :string
    end

    create index(:media, [:poet_id, :content_hash])
  end
end
