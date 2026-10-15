defmodule TravelingPoet.Spaces.ItemReview do
  @moduledoc """
  A resolution the rules could not settle (kb-002): the item a visit was
  attached to, and the other item it might have been. Written when a new
  item is created beside a similar one, so an admin can merge or keep them;
  the raw visits are never rewritten, which is what makes a merge reversible.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "item_reviews" do
    field :reason, :string
    field :status, :string, default: "open"

    belongs_to :item, TravelingPoet.Spaces.Item
    belongs_to :candidate, TravelingPoet.Spaces.Item

    timestamps()
  end

  @doc false
  def changeset(review, attrs) do
    review
    |> cast(attrs, [:item_id, :candidate_id, :reason, :status])
    |> validate_required([:item_id, :candidate_id, :reason, :status])
    |> validate_inclusion(:status, ~w(open kept merged))
  end
end
