defmodule TravelingPoet.Topics.Find do
  @moduledoc """
  Something the poet brought back from an excursion and would send its
  companion to read, watch or look at: a talk, a paper, a product, a session.
  A URL where a place has an address; never geocoded, never in the guide.

  `poet_rating` is the POET's own 1-5, rendered attributed, as with places.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(talk paper product session event venue other)

  schema "entry_finds" do
    field :entry_date, :date
    field :name, :string
    field :url, :string
    field :kind, :string, default: "other"
    field :blurb, :string
    field :poet_rating, :integer
    field :media_id, :id
    field :position, :integer, default: 0
    field :source, :string, default: "agent"

    belongs_to :poet, TravelingPoet.Poets.Poet
    belongs_to :journal_entry, TravelingPoet.Journal.Entry

    timestamps()
  end

  def kinds, do: @kinds

  @doc "Coerces whatever the model sent into a known kind; unknown becomes other."
  def normalize_kind(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in @kinds, do: normalized, else: "other"
  end

  def normalize_kind(_), do: "other"

  @doc false
  def changeset(find, attrs) do
    find
    |> cast(attrs, [
      :poet_id,
      :journal_entry_id,
      :entry_date,
      :name,
      :url,
      :kind,
      :blurb,
      :poet_rating,
      :media_id,
      :position,
      :source
    ])
    |> update_change(:kind, &normalize_kind/1)
    |> update_change(:name, &String.trim/1)
    |> update_change(:url, &String.trim/1)
    |> validate_required([:poet_id, :journal_entry_id, :entry_date, :name, :url, :kind, :position])
    |> validate_length(:name, max: 160)
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:url, ~r/^https?:\/\//, message: "must be an http(s) link")
    |> validate_number(:poet_rating, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> unique_constraint([:journal_entry_id, :name])
  end
end
