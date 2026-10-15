defmodule TravelingPoet.FakeNarrationStorage do
  @moduledoc """
  Stand-in for `Storage.S3` under narration: no bucket. Uploads and deletes
  are sent to the test process as `{:narration_upload, key, bytes}` and
  `{:narration_delete, key}` when it registered itself under
  `:narration_storage_pid`.
  """

  def upload_content(key, bytes, _content_type) do
    notify({:narration_upload, key, bytes})
    {:ok, key}
  end

  def delete_file(key) do
    notify({:narration_delete, key})
    :ok
  end

  # Same shape as `Storage.S3.presigned_get_url/4` (`ExAws.S3.presigned_url/5`
  # returns `{:ok, url}`): the bare string this once returned let a redirect
  # of the raw tuple pass the suite and 500 on every Listen tap in prod.
  def presigned_get_url(key, _expires, filename, disposition),
    do: {:ok, "https://bucket.example/get/#{key}?name=#{filename}&as=#{disposition}"}

  defp notify(msg) do
    case Application.get_env(:traveling_poet, :narration_storage_pid) do
      pid when is_pid(pid) -> send(pid, msg)
      _ -> :ok
    end
  end
end
