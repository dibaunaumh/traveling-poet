defmodule TravelingPoet.AppLoop.Note do
  @moduledoc "One line in an app-side poet's notebook (`AppLoop.Memory`)."

  use Ecto.Schema
  import Ecto.Changeset

  @max_length 500

  schema "app_loop_notes" do
    belongs_to :poet, TravelingPoet.Poets.Poet

    field :entry_date, :date
    field :body, :string
    field :forgotten_on, :date

    timestamps(type: :utc_datetime)
  end

  def max_length, do: @max_length

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:poet_id, :entry_date, :body, :forgotten_on])
    |> update_change(:body, &(&1 && String.trim(&1)))
    |> validate_required([:poet_id, :entry_date, :body])
    |> validate_length(:body, max: @max_length)
  end
end
