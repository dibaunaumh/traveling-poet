defmodule TravelingPoet.Spaces.Link do
  @moduledoc """
  A relation between two items (kb-002), from a fixed set so the graph can be
  traversed: a dish is `at` a restaurant, an exhibition `part_of` a museum's
  season, a work `made_by` an artist, a monument `commemorates` an event, a
  page `about` a place, one item `same_as` another (resolution), this year's
  festival `series_of` last year's.

  `source` says who asserted it: the poet (through a put, with the entry it
  came from), the resolver, or an admin. Phase 0 creates the table and the
  write path; poets start reporting links in phase 2.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @relations ~w(at part_of made_by commemorates about same_as series_of)
  @sources ~w(poet app admin)

  schema "links" do
    field :relation, :string
    field :source, :string, default: "app"

    belongs_to :from_item, TravelingPoet.Spaces.Item
    belongs_to :to_item, TravelingPoet.Spaces.Item
    belongs_to :journal_entry, TravelingPoet.Journal.Entry

    timestamps()
  end

  def relations, do: @relations

  @doc false
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:from_item_id, :to_item_id, :relation, :source, :journal_entry_id])
    |> validate_required([:from_item_id, :to_item_id, :relation, :source])
    |> validate_inclusion(:relation, @relations)
    |> validate_inclusion(:source, @sources)
    |> not_self()
    |> unique_constraint([:from_item_id, :to_item_id, :relation])
  end

  defp not_self(changeset) do
    from = get_field(changeset, :from_item_id)

    if not is_nil(from) and from == get_field(changeset, :to_item_id),
      do: add_error(changeset, :to_item_id, "cannot link an item to itself"),
      else: changeset
  end
end
