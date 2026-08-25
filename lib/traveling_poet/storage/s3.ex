defmodule TravelingPoet.Storage.S3 do
  @moduledoc """
  Tigris (S3-compatible) object storage for journal media (illustrations,
  poet avatars). Uses ExAws + hackney, same stack as alice-in-goals.
  """

  require Logger

  defp bucket, do: Application.fetch_env!(:traveling_poet, :tigris_bucket_name)

  @doc "Uploads binary content under the given object key."
  def upload_content(object_key, content, content_type \\ "application/octet-stream") do
    case ExAws.S3.put_object(bucket(), object_key, content, content_type: content_type)
         |> ExAws.request() do
      {:ok, _response} ->
        {:ok, object_key}

      {:error, reason} ->
        Logger.error("Failed to upload #{object_key} to S3: #{inspect(reason)}")
        {:error, :upload_failed}
    end
  end

  @doc "Downloads a file's bytes."
  def download_file(object_key) do
    case ExAws.S3.get_object(bucket(), object_key) |> ExAws.request() do
      {:ok, %{body: file_contents}} ->
        {:ok, file_contents}

      {:error, reason} ->
        Logger.error("Failed to download #{object_key} from S3: #{inspect(reason)}")
        {:error, :download_failed}
    end
  end

  @doc "Deletes an object."
  def delete_file(object_key) do
    case ExAws.S3.delete_object(bucket(), object_key) |> ExAws.request() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to delete #{object_key} from S3: #{inspect(reason)}")
        {:error, :delete_failed}
    end
  end
end
