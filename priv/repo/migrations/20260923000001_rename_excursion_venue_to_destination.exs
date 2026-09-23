defmodule TravelingPoet.Repo.Migrations.RenameExcursionVenueToDestination do
  use Ecto.Migration

  # "Venue" only fits events; an excursion also goes to a lab, a company, a
  # paper. A stop on a world journey is a place; a stop on a topic journey
  # is a destination.
  def change do
    rename table(:topic_excursions), :requested_venue, to: :requested_destination
    rename table(:topic_excursions), :venue_name, to: :destination_name
    rename table(:topic_excursions), :venue_url, to: :destination_url
  end
end
