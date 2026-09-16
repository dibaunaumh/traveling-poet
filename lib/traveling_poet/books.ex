defmodule TravelingPoet.Books do
  @moduledoc """
  The journal as a book.

  The home page promises that both ways of travelling "end up in the same
  notebook"; this is where that notebook can be taken off the shelf whole.
  The context does the reading (every published day, the poet's path) and
  hands it to `Books.Manuscript`, which is pure and decides the chapters.
  Later phases add the poet's own front matter, a rendered PDF and a copy
  saved to Drive; this is the read model they all share.
  """

  alias TravelingPoet.{Journal, Poets}
  alias TravelingPoet.Books.Manuscript
  alias TravelingPoet.Journal.EntryBundle

  @doc """
  The whole published journal as chapters of days. No 60-entry cap: a book
  is the one place the journey must be complete. Options go to
  `Manuscript.build/4`.
  """
  @spec manuscript(map, keyword) :: Manuscript.t()
  def manuscript(poet, opts \\ []) do
    entries = Journal.list_entries(poet.id, status: "published", limit: :all, order: :asc)
    stays = Poets.list_path_points(poet.id)
    bundles = EntryBundle.load_many(entries, stays: stays)

    Manuscript.build(poet, bundles, stays, opts)
  end
end
