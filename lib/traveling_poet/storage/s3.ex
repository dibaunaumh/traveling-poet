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

  @doc """
  A URL that lets its holder PUT exactly this one object, and nothing else,
  until it expires. Handed to a poet's sprite so it can upload a rendered
  book without ever holding bucket credentials.
  """
  def presigned_put_url(object_key, expires_in_seconds) do
    ExAws.S3.presigned_url(ExAws.Config.new(:s3), :put, bucket(), object_key,
      expires_in: expires_in_seconds
    )
  end

  @doc """
  A short-lived URL to GET one object, served as a download named `filename`.
  """
  def presigned_get_url(object_key, expires_in_seconds, filename) do
    disposition = ~s(attachment; filename="#{String.replace(filename, ~s("), "")}")

    ExAws.S3.presigned_url(ExAws.Config.new(:s3), :get, bucket(), object_key,
      expires_in: expires_in_seconds,
      query_params: [{"response-content-disposition", disposition}]
    )
  end

  @doc "The object's size in bytes, or `{:error, :not_found}`."
  def object_size(object_key) do
    case ExAws.S3.head_object(bucket(), object_key) |> ExAws.request() do
      {:ok, %{headers: headers}} ->
        headers
        |> Enum.find_value(fn {k, v} -> String.downcase(k) == "content-length" && v end)
        |> case do
          nil -> {:error, :no_length}
          v -> {:ok, String.to_integer(v)}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc "The first `length` bytes of an object."
  def read_head(object_key, length) do
    case ExAws.S3.get_object(bucket(), object_key, range: "bytes=0-#{length - 1}")
         |> ExAws.request() do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, _} -> {:error, :not_found}
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
