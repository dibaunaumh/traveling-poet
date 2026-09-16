defmodule TravelingPoet.Books.PdfRenderer do
  @moduledoc """
  Makes a PDF of the book on the poet's sprite and settles the row.

  The app signs a render link for this one PDF (`Books.render_token/1`),
  presigns an upload URL for this one object, starts the render on the
  sprite (`Books.Pdf.SpriteRunner`), holds the sprite awake while polling its
  status, then checks the uploaded object itself before calling it ready.
  A PDF costs no credits and no model call; the daily attempt cap bounds it.
  """

  require Logger

  alias TravelingPoet.{Accounts, Books, Poets, Repo, SpriteHold}
  alias TravelingPoet.Books.Pdf
  alias TravelingPoet.Books.Pdf.{SpriteRunner, Storage}
  alias TravelingPoet.Books.Urls

  @poll_ms 5_000
  # a first render installs headless Chrome (~1 min) before a ~1 min render
  @max_wait_ms 20 * 60 * 1000

  def dispatch(%Pdf{id: id}) do
    Task.start(fn -> run(id) end)
  end

  @doc "Runs one render to the end. Synchronous; `dispatch/1` puts it in a task."
  def run(pdf_id) do
    with %Pdf{status: "rendering"} = pdf <- Repo.get(Pdf, pdf_id),
         poet when not is_nil(poet) <- Poets.get_poet(pdf.poet_id),
         %{sprite_name: sprite} = user when is_binary(sprite) <- Accounts.get_user(poet.user_id) do
      key = Storage.key(poet.id, pdf.id)

      result =
        SpriteHold.with_hold(sprite, "book-pdf", fn ->
          with {:ok, upload_url} <- storage().upload_url(key),
               :ok <-
                 runner().start(sprite, pdf.id, %{
                   url: "#{Urls.base()}/book/render/#{Books.render_token(pdf)}",
                   cookie: nil,
                   upload_url: upload_url,
                   timeout_ms: @max_wait_ms - 60_000,
                   chrome_version: "stable"
                 }),
               {:ok, status} <- wait(sprite, pdf.id, System.monotonic_time(:millisecond)) do
            {:ok, status}
          end
        end)

      settle(pdf, user, sprite, key, result)
    else
      _ -> :skipped
    end
  end

  defp wait(sprite, pdf_id, started) do
    Process.sleep(poll_ms())

    case runner().status(sprite, pdf_id) do
      {:ok, %{"state" => "done"} = status} ->
        {:ok, status}

      {:ok, %{"state" => "failed"} = status} ->
        {:error, {:render_failed, status["error"]}}

      _ ->
        if System.monotonic_time(:millisecond) - started > @max_wait_ms,
          do: {:error, :timed_out},
          else: wait(sprite, pdf_id, started)
    end
  end

  defp settle(pdf, user, sprite, key, {:ok, status}) do
    case storage().verify(key) do
      {:ok, bytes} ->
        runner().cleanup(sprite, pdf.id)

        pdf =
          update(pdf, %{
            status: "ready",
            s3_key: key,
            byte_size: bytes,
            pages: status["pages"],
            rendered_at: DateTime.utc_now() |> DateTime.truncate(:second),
            error: nil
          })

        Logger.info("Books.PdfRenderer: pdf #{pdf.id} ready, #{bytes} bytes, #{pdf.pages} pages")

        Phoenix.PubSub.broadcast(
          TravelingPoet.PubSub,
          "books",
          {:book_pdf_ready, user.id, pdf.id}
        )

        pdf

      {:error, reason} ->
        fail(pdf, sprite, "the uploaded file did not check out (#{inspect(reason)})")
    end
  end

  defp settle(pdf, _user, sprite, _key, {:error, reason}) do
    fail(pdf, sprite, describe(reason))
  end

  defp fail(pdf, sprite, error) do
    log = runner().log_tail(sprite, pdf.id)
    Logger.warning("Books.PdfRenderer: pdf #{pdf.id} failed: #{error}")
    update(pdf, %{status: "failed", error: error, log: log})
  end

  defp update(pdf, attrs) do
    {:ok, pdf} = pdf |> Pdf.changeset(attrs) |> Repo.update()
    Books.broadcast_pdf_updated(pdf)
    pdf
  end

  defp describe({:render_failed, nil}), do: "the render failed on the poet's machine"
  defp describe({:render_failed, msg}), do: "the render failed: #{msg}"
  defp describe(:timed_out), do: "the render did not finish in time"
  defp describe(other), do: "could not start the render: #{inspect(other)}"

  defp runner, do: Application.get_env(:traveling_poet, :book_pdf_runner, SpriteRunner)
  defp storage, do: Storage.impl()
  defp poll_ms, do: Application.get_env(:traveling_poet, :book_pdf_poll_ms, @poll_ms)
end
