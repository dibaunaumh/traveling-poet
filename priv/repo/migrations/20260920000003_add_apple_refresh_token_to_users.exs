defmodule TravelingPoet.Repo.Migrations.AddAppleRefreshTokenToUsers do
  use Ecto.Migration

  # Kept for one purpose: revoking the Sign in with Apple grant when the
  # account is deleted, which Apple requires and which needs this token.
  def change do
    alter table(:users) do
      add :apple_refresh_token, :text
    end
  end
end
