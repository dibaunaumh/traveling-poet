defmodule TravelingPoet.Topics.Find do
  @moduledoc """
  Something the poet brought back from an excursion and would send its
  companion to read, watch or look at: a talk, a paper, a product, a session.
  A URL where a place has an address; never geocoded, never in the guide.

  `poet_rating` is the POET's own 1-5, rendered attributed, as with places.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # music, book, screen and outing come from taste days (a topic with a
  # domain); gadgets and gifts are products.
  # artwork: a piece shown on an art day (an installation, an immersive or
  # XR work), which is neither an event nor a film.
  @kinds ~w(talk paper product session event venue artwork music book screen outing other)

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
    # Where the find sits on the subject tree (Guide.PlaceTopics), as places
    # do; set by Guide.TopicTagging, never by the poet: cast only by
    # topics_changeset/2.
    field :topic, :string
    field :second_topic, :string
    field :topics_classified_at, :utc_datetime

    belongs_to :poet, TravelingPoet.Poets.Poet
    belongs_to :journal_entry, TravelingPoet.Journal.Entry

    timestamps()
  end

  def kinds, do: @kinds

  @doc """
  Which guide filter a kind falls under, the find's twin of
  `Place.group_for/1`: ideas (talks, papers, sessions), things (products),
  happenings (events, venues). "other" belongs to no group but All. One
  function, so the chips, the counts and the stamp inks never disagree.
  """
  def group_for(kind) when kind in ~w(talk paper session), do: "ideas"
  def group_for("product"), do: "things"
  def group_for(kind) when kind in ~w(artwork music book screen), do: "works"
  def group_for(kind) when kind in ~w(event venue outing), do: "happenings"
  def group_for(_), do: "other"

  def filter_groups, do: ~w(all ideas works things happenings)

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
    |> update_change(:blurb, &TravelingPoet.Journal.Blank.clean/1)
    |> validate_required([:poet_id, :journal_entry_id, :entry_date, :name, :url, :kind, :position])
    |> validate_length(:name, max: 160)
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:url, ~r/^https?:\/\//, message: "must be an http(s) link")
    |> validate_number(:poet_rating, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> unique_constraint([:journal_entry_id, :name])
  end

  @topic_fields [:topic, :second_topic, :topics_classified_at]

  @doc "The topic fields, for carrying them across a wholesale replace."
  def topic_fields, do: @topic_fields

  @doc """
  The classifier's verdict on a find. A path not in the tree, or a second
  topic equal to the first, is dropped rather than failing the write.
  """
  def topics_changeset(find, attrs) do
    find
    |> cast(attrs, @topic_fields)
    |> TravelingPoet.Guide.PlaceTopics.drop_unknown_paths([:topic, :second_topic])
  end
end
