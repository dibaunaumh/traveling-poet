defmodule TravelingPoet.Topics.Topic do
  @moduledoc """
  A subject the companion wants their poet to follow beyond places: a field
  they work in, a passion they keep. On some days the poet leaves the road for
  an excursion into one of these (a conference, a festival, a lab, a company)
  and writes back about it.

  A topic is either a subject (`domain` nil: "embodied minds") or a taste in
  a domain (`domain` set: music "post-rock, Sigur Ros"), where the label is
  the companion's taste in their own words and an excursion into it is a day
  discovering new things that fit it. Either way each has its own excursions
  and entries. How the companion likes those entries written (tone, length)
  is a `Preferences.Preference`, not a topic.

  `status`: "proposed" (the poet suggested it from chat; waits for the
  companion to keep it in Settings), "active", "paused". Only active topics
  get scheduled excursions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(professional personal)
  # The domains a taste can be in, in the order the poet asks about them.
  @domains ~w(music books film_tv outdoors gifts)
  @domain_names %{
    "music" => "Music",
    "books" => "Books",
    "film_tv" => "Film & TV",
    "outdoors" => "Outdoors",
    "gifts" => "Gadgets & gifts"
  }
  @statuses ~w(proposed active paused)
  # "settings": typed in by the companion. "chat": proposed by the poet from
  # what the companion said. "ask": the companion's answer to a question the
  # poet asked them (`Asks`), active at once. "onboarding": reserved for a
  # first-run source.
  @sources ~w(settings chat ask onboarding)
  @cadence_range 3..30
  @default_every_days 7

  schema "poet_topics" do
    field :key, :string
    field :label, :string
    field :kind, :string
    field :domain, :string
    field :status, :string, default: "proposed"
    field :source, :string, default: "settings"
    field :every_days, :integer, default: @default_every_days
    field :position, :integer, default: 0
    field :evidence, :map, default: %{}
    # Where the topic or taste sits on the subject tree (Guide.PlaceTopics),
    # set by Guide.TopicTagging: cast only by subjects_changeset/2, and
    # cleared when the label or domain changes so it is classified again.
    field :subject, :string
    field :second_subject, :string
    field :subjects_classified_at, :utc_datetime

    belongs_to :poet, TravelingPoet.Poets.Poet

    timestamps()
  end

  def kinds, do: @kinds
  def domains, do: @domains
  def domain_name(domain), do: Map.get(@domain_names, domain)
  def statuses, do: @statuses
  def sources, do: @sources
  def cadence_range, do: @cadence_range
  def default_every_days, do: @default_every_days

  @doc false
  def changeset(topic, attrs) do
    topic
    |> cast(attrs, [
      :poet_id,
      :label,
      :kind,
      :domain,
      :status,
      :source,
      :every_days,
      :position,
      :evidence
    ])
    |> update_change(:label, &String.trim/1)
    |> validate_required([:poet_id, :label])
    |> validate_length(:label, min: 2, max: 80)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:domain, @domains)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_number(:every_days,
      greater_than_or_equal_to: @cadence_range.first,
      less_than_or_equal_to: @cadence_range.last
    )
    |> put_key()
    |> unique_constraint([:poet_id, :key], message: "already follows this topic")
    |> reset_subjects()
  end

  # New words mean a new place on the tree.
  defp reset_subjects(%{data: %{id: id}} = changeset) when not is_nil(id) do
    if get_change(changeset, :label) || get_change(changeset, :domain),
      do: change(changeset, subject: nil, second_subject: nil, subjects_classified_at: nil),
      else: changeset
  end

  defp reset_subjects(changeset), do: changeset

  @doc "The classifier's verdict on a topic or taste; unknown paths are dropped."
  def subjects_changeset(topic, attrs) do
    topic
    |> cast(attrs, [:subject, :second_subject, :subjects_classified_at])
    |> TravelingPoet.Guide.PlaceTopics.drop_unknown_paths([:subject, :second_subject])
  end

  # Groups a topic by what it is about, ignoring how it was phrased, so
  # "Experimental music" proposed twice is one topic.
  defp put_key(changeset) do
    case get_change(changeset, :label) do
      nil -> changeset
      label -> put_change(changeset, :key, derive_key(label))
    end
  end

  def derive_key(label) when is_binary(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
  end
end
