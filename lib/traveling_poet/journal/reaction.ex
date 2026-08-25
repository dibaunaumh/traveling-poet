defmodule TravelingPoet.Journal.Reaction do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(love inspiring want_more not_for_me)
  @visibilities ~w(private public)

  schema "reactions" do
    field :kind, :string
    field :visibility, :string
    field :note, :string

    belongs_to :journal_entry, TravelingPoet.Journal.Entry
    belongs_to :user, TravelingPoet.Accounts.User

    timestamps()
  end

  def kinds, do: @kinds

  @doc false
  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:journal_entry_id, :user_id, :kind, :visibility, :note])
    |> validate_required([:journal_entry_id, :user_id, :kind, :visibility])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:visibility, @visibilities)
    |> unique_constraint([:journal_entry_id, :user_id, :kind, :visibility])
  end
end
