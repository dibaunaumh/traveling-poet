defmodule TravelingPoet.Repo.Migrations.RetryGooglePlaceMisses do
  use Ecto.Migration

  # The matcher now also accepts "Street"/"St", run-together names and a
  # square named by its address; look up the places it missed again.
  def up, do: execute("DELETE FROM google_place_ids WHERE place_id IS NULL")
  def down, do: :ok
end
