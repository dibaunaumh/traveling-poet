defmodule TravelingPoet.Repo.Migrations.ClearGooglePlaceIdsForNameCheck do
  use Ecto.Migration

  # The ids found before the name check include guesses Google made for
  # places it does not know (Szara Kazimierz came back as Starka, evt-471).
  # Forget them so every place is looked up again and checked.
  def up, do: execute("DELETE FROM google_place_ids")
  def down, do: :ok
end
