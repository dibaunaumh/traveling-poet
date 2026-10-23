defmodule TravelingPoet.Repo.Migrations.ClearGooglePlaceIds do
  use Ecto.Migration

  # The first lookups searched two km around each place and matched a
  # namesake branch across town (evt-470). The box is now ~800 m; forget
  # what the wider search found so every place is looked up again.
  def up, do: execute("DELETE FROM google_place_ids")
  def down, do: :ok
end
