defmodule TravelingPoet.Bookmarks.Bookmark do
  @moduledoc """
  A place or find a reader saved. Keyed by the page it came from and its
  name, not its id: a poet's re-put replaces a page's places and finds
  wholesale, so an id would not survive a revision. `snapshot` keeps what the
  reader saw, for when the item is gone from the page.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(place find)

  schema "bookmarks" do
    field :kind, :string
    field :name, :string
    field :snapshot, :map, default: %{}

    belongs_to :user, TravelingPoet.Accounts.User
    belongs_to :poet, TravelingPoet.Poets.Poet
    belongs_to :journal_entry, TravelingPoet.Journal.Entry

    timestamps()
  end

  def kinds, do: @kinds

  def changeset(bookmark, attrs) do
    bookmark
    |> cast(attrs, [:user_id, :kind, :poet_id, :journal_entry_id, :name, :snapshot])
    |> validate_required([:user_id, :kind, :name])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:user_id, :kind, :journal_entry_id, :name])
  end
end
