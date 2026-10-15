defmodule TravelingPoet.Spaces.ReferenceSystem do
  @moduledoc """
  A space, in the Spaces model (kb-002): a coordinate system an item can be
  placed in, stored as data so a deployment chooses its own. The travel
  deployment seeds three (migration `CreateSpaces`): `geo` (metric, lat/lng),
  `subject` (tree, `Guide.PlaceTopics` paths) and `time` (dates and eras).
  A company deployment adds a `hierarchy` for its organisation.

  `near` means something different per type: distance for `metric`, a shared
  ancestor for `hierarchy`, a shared prefix for `tree`, overlap for `time`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(metric hierarchy tree time)

  schema "reference_systems" do
    field :key, :string
    field :name, :string
    field :type, :string
    field :config, :map, default: %{}

    timestamps()
  end

  def types, do: @types

  @doc false
  def changeset(system, attrs) do
    system
    |> cast(attrs, [:key, :name, :type, :config])
    |> validate_required([:key, :name, :type])
    |> validate_inclusion(:type, @types)
    |> unique_constraint(:key)
  end
end
