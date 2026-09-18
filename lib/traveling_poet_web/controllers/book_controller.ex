defmodule TravelingPoetWeb.BookController do
  @moduledoc """
  The owner's journal as one printable book.

  A plain page under its own root layout (no app chrome), because paged.js
  takes the flowing document apart into pages on the client and LiveView
  would patch it straight back. Free: it is the owner's own journal, read
  whole. `?size=` picks the paper.

  When the poet has composed an edition, its words are bound in (dedication,
  foreword, chapter openers, pull quotes, epilogue); `?edition=plain` prints
  the journal as written instead.
  """

  use TravelingPoetWeb, :controller

  alias TravelingPoet.{Accounts, Books, GoogleDrive, Poets}
  alias TravelingPoet.Books.Matter
  alias TravelingPoet.Books.Pdf.Storage
  alias TravelingPoetWeb.Layouts

  @sizes [{"a5", "A5"}, {"a4", "A4"}, {"letter", "letter"}]
  @default_key "a5"
  @render_cookie "tp_book_render"

  def render_cookie, do: @render_cookie

  def show(conn, params) do
    user = conn.assigns.current_user

    case Poets.get_poet_by_user(user.id) do
      nil ->
        redirect(conn, to: ~p"/onboarding")

      poet ->
        composed = Books.latest_ready_edition(poet)
        edition = if params["edition"] == "plain", do: nil, else: composed

        render_book(conn, poet, user,
          size_key: size_key(params["size"]),
          edition: edition,
          has_composed: not is_nil(composed),
          composing: Books.composing?(poet),
          pdf_enabled: Books.pdf_enabled?(user),
          render_mode: false
        )
    end
  end

  @doc """
  The same book, opened by the poet's sprite to print a PDF. The token names
  one PDF that is still rendering; the page carries no toolbar, and a cookie
  scoped to /media lets its drawings load for a private poet.
  """
  def render_pdf(conn, %{"token" => token}) do
    with {:ok, pdf} <- Books.verify_render_token(token),
         poet when not is_nil(poet) <- Poets.get_poet(pdf.poet_id),
         user when not is_nil(user) <- Accounts.get_user(poet.user_id) do
      edition = pdf.edition_id && Books.get_edition(pdf.edition_id)
      edition = if match?(%{status: "ready"}, edition), do: edition, else: nil

      conn
      |> put_resp_cookie(@render_cookie, token,
        path: "/media",
        http_only: true,
        same_site: "Lax",
        max_age: 30 * 60
      )
      |> put_resp_header("x-robots-tag", "noindex")
      |> render_book(poet, user,
        size_key: pdf.page_size,
        edition: edition,
        has_composed: false,
        composing: false,
        pdf_enabled: false,
        render_mode: true
      )
    else
      _ -> conn |> put_status(403) |> text("This link has expired.")
    end
  end

  @doc """
  Sends the owner to Google to add Drive access (drive.file) on top of
  sign-in. The PDF to save is parked in the session and picked up by
  AuthController.callback/2 on the way back.
  """
  def connect_drive(conn, params) do
    user = conn.assigns.current_user

    conn
    |> put_session(:google_connect, %{
      "feature" => "drive",
      "pdf" => params["pdf"],
      "user_id" => user.id
    })
    |> redirect(to: "/auth/google?" <> URI.encode_query(GoogleDrive.consent_params(user)))
  end

  @doc "Hands the owner a short-lived link to their stored PDF."
  def download_pdf(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {pdf_id, ""} <- Integer.parse(id),
         %{} = pdf <- Books.get_owned_pdf(user, pdf_id),
         poet when not is_nil(poet) <- Poets.get_poet(pdf.poet_id),
         {:ok, url} <- Storage.impl().download_url(pdf.s3_key, Books.pdf_filename(poet, pdf)) do
      redirect(conn, external: url)
    else
      _ -> conn |> put_status(404) |> text("That PDF is not available.")
    end
  end

  defp render_book(conn, poet, user, opts) do
    manuscript = Books.manuscript(poet)
    size_key = opts[:size_key]
    edition = opts[:edition]

    conn
    |> put_root_layout(html: {Layouts, :book})
    |> put_layout(false)
    |> assign(:page_title, "#{poet.name}: the book")
    |> render(:show,
      poet: poet,
      companion: first_name(user.name),
      manuscript: manuscript,
      page_size: page_size(size_key),
      size_key: size_key,
      sizes: @sizes,
      edition: edition,
      has_composed: opts[:has_composed],
      matter: edition && Matter.for_render(edition.matter, manuscript),
      composing: opts[:composing],
      pdf_enabled: opts[:pdf_enabled],
      render_mode: opts[:render_mode]
    )
  end

  defp first_name(name) when is_binary(name) do
    case String.split(String.trim(name)) do
      [first | _] -> first
      [] -> nil
    end
  end

  defp first_name(_name), do: nil

  defp size_key(key) do
    case List.keyfind(@sizes, key || "", 0) do
      {key, _size} -> key
      nil -> @default_key
    end
  end

  # Whitelisted: this string lands inside a <style> tag.
  defp page_size(key) do
    {_key, size} = List.keyfind(@sizes, key, 0)
    size
  end
end
