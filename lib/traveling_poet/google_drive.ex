defmodule TravelingPoet.GoogleDrive do
  @moduledoc """
  The companion's Google Drive, for saving the book's PDF.

  The grant is `drive.file`: the app can see and change only files it made
  there, nothing else in their Drive. It is asked for separately from sign-in
  (incremental consent through the same Google OAuth client), with
  `access_type=offline` so a save can run in the background later.

  Uploads go into a "Traveling Poet" folder the app makes once, by
  resumable upload: Drive's single-request upload stops at 5 MB and a book
  is more.

  Every request goes through `req_options/0`, stubbed with `Req.Test` in the
  suite (`:drive_req_options`); nothing here reaches Google from a test.
  """

  require Logger

  alias TravelingPoet.Accounts
  alias TravelingPoet.Accounts.User

  @scope "https://www.googleapis.com/auth/drive.file"
  @token_url "https://oauth2.googleapis.com/token"
  @revoke_url "https://oauth2.googleapis.com/revoke"
  @files_url "https://www.googleapis.com/drive/v3/files"
  @upload_url "https://www.googleapis.com/upload/drive/v3/files"
  @folder_name "Traveling Poet"
  @folder_mime "application/vnd.google-apps.folder"

  def scope, do: @scope

  @doc "The Google sign-in path that asks for Drive access on top of sign-in."
  def consent_params(email) do
    [
      scope: "email profile #{@scope}",
      access_type: "offline",
      prompt: "consent",
      login_hint: email
    ]
  end

  def connected?(%User{drive_refresh_token: t}) when is_binary(t) and t != "", do: true
  def connected?(_user), do: false

  @doc """
  Keeps the Drive grant from an OAuth callback. `{:error, :no_drive_scope}`
  when the companion unticked Drive on the consent screen, `{:error,
  :no_refresh_token}` when Google gave no offline access.
  """
  def store_credentials(%User{} = user, %{scopes: scopes} = credentials) do
    cond do
      @scope not in List.wrap(scopes) ->
        {:error, :no_drive_scope}

      credentials.refresh_token in [nil, ""] ->
        {:error, :no_refresh_token}

      true ->
        Accounts.update_user(user, %{
          drive_refresh_token: credentials.refresh_token,
          drive_access_token: credentials.token,
          drive_token_expires_at: expires_at(credentials.expires_at),
          drive_connected_at: now()
        })
    end
  end

  @doc "Revokes the grant with Google (best effort) and forgets it."
  def disconnect(%User{} = user) do
    if connected?(user) do
      case Req.post(@revoke_url, [form: [token: user.drive_refresh_token]] ++ req_options()) do
        {:ok, %{status: s}} when s in 200..299 -> :ok
        other -> Logger.info("GoogleDrive: revoke answered #{inspect(other)}; forgetting anyway")
      end
    end

    forget(user)
  end

  @doc """
  Uploads a PDF into the companion's "Traveling Poet" folder. Returns
  `{:ok, %{id, web_link}}`, `{:error, :reconnect}` when the grant is gone,
  or `{:error, reason}`.
  """
  def upload_pdf(%User{} = user, bytes, filename) when is_binary(bytes) do
    with {:ok, user, token} <- access_token(user),
         {:ok, _user, folder_id} <- ensure_folder(user, token),
         {:ok, location} <- start_upload(token, folder_id, filename, byte_size(bytes)),
         {:ok, file} <- finish_upload(token, location, bytes) do
      {:ok, %{id: file["id"], web_link: file["webViewLink"]}}
    end
  end

  @doc false
  # A usable access token, refreshed when it is within a minute of expiring.
  def access_token(%User{} = user) do
    fresh? =
      user.drive_access_token not in [nil, ""] and user.drive_token_expires_at &&
        DateTime.compare(user.drive_token_expires_at, DateTime.add(DateTime.utc_now(), 60)) == :gt

    if fresh?, do: {:ok, user, user.drive_access_token}, else: refresh(user)
  end

  defp refresh(%User{drive_refresh_token: refresh}) when refresh in [nil, ""],
    do: {:error, :reconnect}

  defp refresh(%User{} = user) do
    oauth = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, [])

    form = [
      grant_type: "refresh_token",
      refresh_token: user.drive_refresh_token,
      client_id: oauth[:client_id],
      client_secret: oauth[:client_secret]
    ]

    case Req.post(@token_url, [form: form] ++ req_options()) do
      {:ok, %{status: 200, body: %{"access_token" => token} = body}} ->
        {:ok, user} =
          Accounts.update_user(user, %{
            drive_access_token: token,
            drive_token_expires_at: DateTime.add(now(), body["expires_in"] || 3600)
          })

        {:ok, user, token}

      {:ok, %{status: status, body: %{"error" => "invalid_grant"}}} when status in 400..401 ->
        # revoked in their Google account, or expired: ask them to reconnect
        forget(user)
        {:error, :reconnect}

      other ->
        {:error, {:token, summarize(other)}}
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

  defp forget(user) do
    Accounts.update_user(user, %{
      drive_refresh_token: nil,
      drive_access_token: nil,
      drive_token_expires_at: nil,
      drive_connected_at: nil
    })
  end

  defp summarize({:ok, %{status: status, body: body}}),
    do: "HTTP #{status}: #{inspect(body) |> String.slice(0, 200)}"

  defp summarize({:error, reason}), do: inspect(reason) |> String.slice(0, 200)
  defp summarize(other), do: inspect(other) |> String.slice(0, 200)

  defp expires_at(unix) when is_integer(unix),
    do: DateTime.from_unix!(unix) |> DateTime.truncate(:second)

  defp expires_at(_), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  def req_options, do: Application.get_env(:traveling_poet, :drive_req_options, [])
end
