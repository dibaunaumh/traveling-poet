defmodule TravelingPoet.Bookmarks.Pass do
  @moduledoc """
  A place or find a reader marked "Not for me" (card-123). Keyed like a
  `Bookmark`, by the page and the name, so it survives the poet's re-put.
  It keeps the item's subject on the subject tree (`topic`, `second_topic`)
  and its category, because that is what the reader said no to: the taste
  profile (`Affinity`) counts it against the subject, and the poet gets a
  nudge away from it (`Preferences`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "passes" do
    field :kind, :string
    field :name, :string
    field :category, :string
    field :topic, :string
    field :second_topic, :string

    belongs_to :user, TravelingPoet.Accounts.User
    belongs_to :poet, TravelingPoet.Poets.Poet
    belongs_to :journal_entry, TravelingPoet.Journal.Entry

    timestamps()
  end

  def changeset(pass, attrs) do
    pass
    |> cast(attrs, [
      :user_id,
      :kind,
      :poet_id,
      :journal_entry_id,
      :name,
      :category,
      :topic,
      :second_topic
    ])
    |> validate_required([:user_id, :kind, :name])
    |> validate_inclusion(:kind, TravelingPoet.Bookmarks.Bookmark.kinds())
    |> unique_constraint([:user_id, :kind, :journal_entry_id, :name])
  end
end
