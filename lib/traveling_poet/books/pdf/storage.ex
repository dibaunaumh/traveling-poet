defmodule TravelingPoet.Books.Pdf.Storage do
  @moduledoc """
  Where rendered books live: the media bucket, under `poets/:id/books/`.
  A module of its own so the suite can swap it (`:book_pdf_storage`) and never
  reach Tigris.
  """

  alias TravelingPoet.Storage.S3

  @callback upload_url(key :: String.t()) :: {:ok, String.t()} | {:error, term}
  @callback download_url(
              key :: String.t(),
              filename :: String.t(),
              disposition :: :attachment | :inline
            ) :: {:ok, String.t()} | {:error, term}
  @callback verify(key :: String.t()) :: {:ok, non_neg_integer} | {:error, term}
  @callback delete(key :: String.t()) :: :ok | {:error, term}

  @upload_ttl 3600
  # The app's own download link (/journal/book/pdf/:id) never expires; each
  # click mints this bucket link, which lasts an hour so a slow start or a
  # copied link still works.
  @download_ttl 3600
  # sanity bound; a 300-page book with drawings compresses to tens of MB
  @max_bytes 250_000_000

  def impl, do: Application.get_env(:traveling_poet, :book_pdf_storage, __MODULE__)

  def key(poet_id, pdf_id), do: "poets/#{poet_id}/books/book-#{pdf_id}.pdf"

  def upload_url(key), do: S3.presigned_put_url(key, @upload_ttl)

  def download_url(key, filename, disposition \\ :attachment),
    do: S3.presigned_get_url(key, @download_ttl, filename, disposition)

  @doc "The uploaded object exists, is a PDF, and is a sane size. The app's own check: the sprite's word is not enough."
  def verify(key) do
    with {:ok, size} when size > 0 <- S3.object_size(key),
         true <- size <= @max_bytes || {:error, :too_large},
         {:ok, "%PDF-"} <- S3.read_head(key, 5) do
      {:ok, size}
    else
      {:ok, 0} -> {:error, :empty}
      {:ok, _other_head} -> {:error, :not_a_pdf}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete(key), do: S3.delete_file(key)
end
