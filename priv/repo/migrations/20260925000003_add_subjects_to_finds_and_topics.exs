defmodule TravelingPoet.Repo.Migrations.AddSubjectsToFindsAndTopics do
  use Ecto.Migration

  # Finds and topics (tastes and subjects) on the same subject tree as places
  # (Guide.PlaceTopics): up to two paths each, and when they were classified.
  def change do
    alter table(:entry_finds) do
      add :topic, :string
      add :second_topic, :string
      add :topics_classified_at, :utc_datetime
    end

    alter table(:poet_topics) do
      add :subject, :string
      add :second_subject, :string
      add :subjects_classified_at, :utc_datetime
    end
  end
end
