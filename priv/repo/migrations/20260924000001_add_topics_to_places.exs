defmodule TravelingPoet.Repo.Migrations.AddTopicsToPlaces do
  use Ecto.Migration

  # Guide.PlaceTopics: up to two third-level topic paths per place, a short
  # place type, and when the classifier last looked at it. A classified place
  # with no topic is a row that is not really a place (a town mentioned in
  # passing, an organisation); topics_classified_at keeps it from being paid
  # for again.
  def change do
    alter table(:places) do
      add :topic, :string
      add :second_topic, :string
      add :place_type, :string
      add :topics_classified_at, :utc_datetime
    end

    create index(:places, [:topic])
    create index(:places, [:second_topic])
  end
end
