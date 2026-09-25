defmodule TravelingPoet.Repo.Migrations.AddDomainToPoetTopics do
  use Ecto.Migration

  def change do
    alter table(:poet_topics) do
      # nil: a subject ("embodied minds"); else a taste in a domain (music...)
      add :domain, :string
    end
  end
end
