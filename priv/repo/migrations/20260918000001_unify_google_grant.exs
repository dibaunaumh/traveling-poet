defmodule TravelingPoet.Repo.Migrations.UnifyGoogleGrant do
  use Ecto.Migration

  # Google issues ONE grant per user per OAuth client, whatever it was asked
  # for. The Drive tokens were stored as Drive's, but revoking that refresh
  # token revokes every scope on the grant, and a later consent for another
  # feature (Calendar) replaces it. So the tokens are the account's, with the
  # list of feature scopes they carry; per-feature state is only when it was
  # connected. Existing Drive grants carry drive.file and nothing else.
  @drive_scope "https://www.googleapis.com/auth/drive.file"

  def change do
    rename table(:users), :drive_refresh_token, to: :google_refresh_token
    rename table(:users), :drive_access_token, to: :google_access_token
    rename table(:users), :drive_token_expires_at, to: :google_token_expires_at

    alter table(:users) do
      # feature scopes the stored refresh token was granted (full scope URLs)
      add :google_scopes, {:array, :string}, default: "[]", null: false
    end

    execute(
      """
      UPDATE users SET google_scopes = '["#{@drive_scope}"]'
      WHERE google_refresh_token IS NOT NULL AND google_refresh_token != ''
      """,
      ""
    )
  end
end
