defmodule TravelingPoet.Repo.Migrations.AddNearHomeCardHiddenWeekToUsers do
  use Ecto.Migration

  def change do
    # The week of picks near home (card-71) whose journal card the reader
    # closed; the next week's picks bring it back.
    alter table(:users) do
      add :near_home_card_hidden_week, :date
    end
  end
end
