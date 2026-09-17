defmodule TravelingPoet.Repo.Migrations.AddGoogleDrive do
  use Ecto.Migration

  # Saving the book's PDF to the companion's Google Drive. The grant is
  # drive.file only: the app sees nothing in their Drive but the files it
  # made. The tokens are credentials (redacted from the change stream by
  # name) and are forgotten, and revoked with Google, on disconnect.
  def change do
    alter table(:users) do
      add :drive_refresh_token, :string
      add :drive_access_token, :string
      add :drive_token_expires_at, :utc_datetime
      add :drive_connected_at, :utc_datetime
      # the "Traveling Poet" folder the app made in their Drive
      add :drive_folder_id, :string
    end

    alter table(:book_pdfs) do
      # saving | saved | failed
      add :drive_status, :string
      add :drive_file_id, :string
      add :drive_web_link, :string
      add :drive_error, :string
      add :drive_saved_at, :utc_datetime
    end
  end
end
