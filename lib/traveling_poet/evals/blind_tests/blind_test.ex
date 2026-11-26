defmodule TravelingPoet.Evals.BlindTests.BlindTest do
  @moduledoc "One blind test: an eval manifest and the judge's votes."
  use Ecto.Schema
  import Ecto.Changeset

  schema "blind_tests" do
    field :name, :string
    field :title, :string
    field :manifest, :map
    field :votes, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(test, attrs) do
    test
    |> cast(attrs, [:name, :title, :manifest, :votes])
    |> validate_required([:name, :manifest])
    |> unique_constraint(:name)
  end
end
