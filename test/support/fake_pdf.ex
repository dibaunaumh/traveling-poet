defmodule TravelingPoet.FakePdfRunner do
  @moduledoc """
  Stand-in for `Books.Pdf.SpriteRunner` in tests. Reports calls to the pid in
  `:fake_pdf_listener` and answers `status/2` with `:fake_pdf_status`
  (default: a finished 12-page render).
  """

  def start(sprite, pdf_id, job) do
    notify({:pdf_start, sprite, pdf_id, job})
    Application.get_env(:traveling_poet, :fake_pdf_start, :ok)
  end

  def status(_sprite, _pdf_id) do
    {:ok,
     Application.get_env(:traveling_poet, :fake_pdf_status, %{
       "state" => "done",
       "pages" => 12,
       "bytes" => 4096
     })}
  end

  def log_tail(_sprite, _pdf_id), do: "laid out 12 pages\nprinted"

  def cleanup(sprite, pdf_id) do
    notify({:pdf_cleanup, sprite, pdf_id})
    :ok
  end

  defp notify(msg) do
    case Application.get_env(:traveling_poet, :fake_pdf_listener) do
      pid when is_pid(pid) -> send(pid, msg)
      _ -> :ok
    end
  end
end

defmodule TravelingPoet.FakePdfStorage do
  @moduledoc "Stand-in for `Books.Pdf.Storage`: no bucket; `verify/1` answers `:fake_pdf_verify`."

  def upload_url(key), do: {:ok, "https://bucket.example/put/#{key}?X-Amz-Signature=abc"}

  def download_url(key, filename),
    do: {:ok, "https://bucket.example/get/#{key}?name=#{URI.encode_www_form(filename)}"}

  def verify(_key), do: Application.get_env(:traveling_poet, :fake_pdf_verify, {:ok, 4096})
  def delete(_key), do: :ok
end
