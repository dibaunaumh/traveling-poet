defmodule TravelingPoetWeb.BookController do
  @moduledoc """
  The owner's journal as one printable book.

  A plain page under its own root layout (no app chrome), because paged.js
  takes the flowing document apart into pages on the client and LiveView
  would patch it straight back. Free: it is the owner's own journal, read
  whole. `?size=` picks the paper.
  """

  use TravelingPoetWeb, :controller

  alias TravelingPoet.{Books, Poets}
  alias TravelingPoetWeb.Layouts

  @sizes [{"a5", "A5"}, {"a4", "A4"}, {"letter", "letter"}]
  @default_size "A5"

  def show(conn, params) do
    user = conn.assigns.current_user

    case Poets.get_poet_by_user(user.id) do
      nil ->
        redirect(conn, to: ~p"/onboarding")

      poet ->
        size = page_size(params["size"])
        manuscript = Books.manuscript(poet)

        conn
        |> put_root_layout(html: {Layouts, :book})
        |> put_layout(false)
        |> assign(:page_title, "#{poet.name}: the book")
        |> render(:show, poet: poet, manuscript: manuscript, page_size: size, sizes: @sizes)
    end
  end

  # Whitelisted: this string lands inside a <style> tag.
  defp page_size(key) do
    case List.keyfind(@sizes, key || "", 0) do
      {_key, size} -> size
      nil -> @default_size
    end
  end
end
