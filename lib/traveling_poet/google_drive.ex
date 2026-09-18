defmodule TravelingPoet.GoogleDrive do
  @moduledoc """
  The companion's Google Drive, for saving the book's PDF.

  The grant is `drive.file`: the app can see and change only files it made
  there, nothing else in their Drive. It is one feature of the account's
  Google grant (`TravelingPoet.GoogleAuth`), asked for separately from
  sign-in with offline access so a save can run in the background later.

  Uploads go into a "Traveling Poet" folder the app makes once, by
  resumable upload: Drive's single-request upload stops at 5 MB and a book
  is more.

  Every request goes through `GoogleAuth.req_options/0`, stubbed with
  `Req.Test` in the suite; nothing here reaches Google from a test.
  """

  alias TravelingPoet.Accounts
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.GoogleAuth

  @files_url "https://www.googleapis.com/drive/v3/files"
  @upload_url "https://www.googleapis.com/upload/drive/v3/files"
  @folder_name "Traveling Poet"
  @folder_mime "application/vnd.google-apps.folder"

  def scope, do: GoogleAuth.scope(:drive)

  @doc "The Google sign-in query that asks for Drive access on top of sign-in."
  def consent_params(%User{} = user), do: GoogleAuth.consent_params(user, :drive)

  def connected?(user), do: GoogleAuth.connected?(user, :drive)

  @doc """
  Keeps the Drive grant from an OAuth callback. `{:error, :no_drive_scope}`
  when the companion unticked Drive on the consent screen, `{:error,
  :no_refresh_token}` when Google gave no offline access.
  """
  def store_credentials(%User{} = user, credentials) do
    case GoogleAuth.store_credentials(user, credentials, :drive) do
      {:error, :scope_not_granted} -> {:error, :no_drive_scope}
      other -> other
    end
  end

  @doc "Forgets Drive; the grant is revoked with Google once no feature uses it."
  def disconnect(%User{} = user), do: GoogleAuth.disconnect(user, :drive)

  @doc """
  Uploads a PDF into the companion's "Traveling Poet" folder. Returns
  `{:ok, %{id, web_link}}`, `{:error, :reconnect}` when the grant is gone,
  or `{:error, reason}`.
  """
  def upload_pdf(%User{} = user, bytes, filename) when is_binary(bytes) do
    with {:ok, user, token} <- GoogleAuth.access_token(user),
         {:ok, _user, folder_id} <- ensure_folder(user, token),
         {:ok, location} <- start_upload(token, folder_id, filename, byte_size(bytes)),
         {:ok, file} <- finish_upload(token, location, bytes) do
      {:ok, %{id: file["id"], web_link: file["webViewLink"]}}
    end
  end

  # The folder the app made, made again if it was deleted or trashed.
  defp ensure_folder(%User{drive_folder_id: id} = user, token) when is_binary(id) and id != "" do
    case Req.get(
           "#{@files_url}/#{id}",
           [auth: {:bearer, token}, params: [fields: "id,trashed"]] ++ req_options()
         ) do
      {:ok, %{status: 200, body: %{"trashed" => false}}} -> {:ok, user, id}
      {:ok, %{status: s}} when s in [200, 404] -> create_folder(user, token)
      {:ok, %{status: 401}} -> {:error, :reconnect}
      other -> {:error, {:folder, summarize(other)}}
    end
  end

  defp ensure_folder(user, token), do: create_folder(user, token)

  defp create_folder(user, token) do
    request =
      [
        auth: {:bearer, token},
        params: [fields: "id"],
        json: %{name: @folder_name, mimeType: @folder_mime}
      ] ++
        req_options()

    case Req.post(@files_url, request) do
      {:ok, %{status: 200, body: %{"id" => id}}} ->
        {:ok, user} = Accounts.update_user(user, %{drive_folder_id: id})
        {:ok, user, id}

      {:ok, %{status: 401}} ->
        {:error, :reconnect}

      other ->
        {:error, {:folder, summarize(other)}}
    end
  end

  defp start_upload(token, folder_id, filename, size) do
    request =
      [
        auth: {:bearer, token},
        params: [uploadType: "resumable", fields: "id,webViewLink"],
        headers: [
          {"x-upload-content-type", "application/pdf"},
          {"x-upload-content-length", Integer.to_string(size)}
        ],
        json: %{name: filename, mimeType: "application/pdf", parents: [folder_id]}
      ] ++ req_options()

    case Req.post(@upload_url, request) do
      {:ok, %{status: 200} = resp} ->
        case Req.Response.get_header(resp, "location") do
          [location | _] -> {:ok, location}
          [] -> {:error, {:upload, "no upload location"}}
        end

      {:ok, %{status: 401}} ->
        {:error, :reconnect}

      other ->
        {:error, {:upload, summarize(other)}}
    end
  end

  defp finish_upload(token, location, bytes) do
    request =
      [
        auth: {:bearer, token},
        headers: [{"content-type", "application/pdf"}],
        body: bytes,
        receive_timeout: 120_000
      ] ++ req_options()

    case Req.put(location, request) do
      {:ok, %{status: s, body: %{"id" => _} = file}} when s in [200, 201] -> {:ok, file}
      {:ok, %{status: 401}} -> {:error, :reconnect}
      other -> {:error, {:upload, summarize(other)}}
    end
  end

  defp summarize({:ok, %{status: status, body: body}}),
    do: "HTTP #{status}: #{inspect(body) |> String.slice(0, 200)}"

  defp summarize({:error, reason}), do: inspect(reason) |> String.slice(0, 200)
  defp summarize(other), do: inspect(other) |> String.slice(0, 200)

  defp req_options, do: GoogleAuth.req_options()
end
