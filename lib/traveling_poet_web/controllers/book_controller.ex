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

  alias TravelingPoet.{Books, Poets}
  alias TravelingPoet.Books.Matter
  alias TravelingPoetWeb.Layouts

  @sizes [{"a5", "A5"}, {"a4", "A4"}, {"letter", "letter"}]
  @default_key "a5"

  def show(conn, params) do
    user = conn.assigns.current_user

    case Poets.get_poet_by_user(user.id) do
      nil ->
        redirect(conn, to: ~p"/onboarding")

      poet ->
        size_key = size_key(params["size"])
        manuscript = Books.manuscript(poet)
        composed = Books.latest_ready_edition(poet)
        plain? = params["edition"] == "plain"
        edition = if plain?, do: nil, else: composed

        conn
        |> put_root_layout(html: {Layouts, :book})
        |> put_layout(false)
        |> assign(:page_title, "#{poet.name}: the book")
        |> render(:show,
          poet: poet,
          manuscript: manuscript,
          page_size: page_size(size_key),
          size_key: size_key,
          sizes: @sizes,
          edition: edition,
          has_composed: not is_nil(composed),
          matter: edition && Matter.for_render(edition.matter, manuscript),
          composing: Books.composing?(poet)
        )
    end
  end

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
