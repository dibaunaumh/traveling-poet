defmodule TravelingPoet.Reading.ParagraphRead do
  @moduledoc """
  How long the owner of a journal had one paragraph of it on screen on one
  day. Keyed like `Journal.ParagraphSubject`, by the paragraph's text
  (`Journal.Paragraphs.key/1`), so it joins to the paragraph's subjects.
  `chars` is the paragraph's length, so the time can be judged against it
  (a read-through, a skim, a skip) when the taste profile is built.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "paragraph_reads" do
    field :key, :string
    field :read_on, :date
    field :ms, :integer, default: 0
    field :chars, :integer

    belongs_to :user, TravelingPoet.Accounts.User
    belongs_to :journal_entry, TravelingPoet.Journal.Entry

    timestamps()
  end

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, [:user_id, :journal_entry_id, :key, :read_on, :ms, :chars])
    |> validate_required([:user_id, :journal_entry_id, :key, :read_on, :ms, :chars])
    |> validate_number(:ms, greater_than_or_equal_to: 0)
    |> unique_constraint([:user_id, :journal_entry_id, :key, :read_on])
  end
end
