defmodule TravelingPoet.Preferences.Preference do
  @moduledoc """
  One thing the poet has learned about its companion — "more of the strange,
  less of the pretty" — with where it came from and how firmly it is held.

  `key` omits polarity on purpose: "more museums" and "fewer museums" are the
  same question answered differently, so they share `topic:museums` and the
  later answer overwrites the earlier one instead of both being true at once.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # What the preference is about. Deliberately coarse: these map onto choices
  # the poet actually makes on a run, not onto arbitrary taxonomy.
  @dimensions ~w(topic tone pace length place format)
  @polarities ~w(seek avoid)
  # Where it came from. `tap` and `settings` are the user's own words or
  # deliberate choice; `chat`, `reaction` and `marker` are inferred, and
  # inferred sources are not allowed to resurrect something the user has
  # removed. `marker` is what the poet generalised from the markers left on
  # entries.
  @sources ~w(tap chat settings onboarding reaction marker)
  @statuses ~w(active dismissed)

  schema "poet_preferences" do
    field :key, :string
    field :label, :string
    field :dimension, :string
    field :polarity, :string
    field :source, :string
    field :status, :string, default: "active"
    field :weight, :integer, default: 1
    field :evidence, :map, default: %{}
    field :last_confirmed_at, :utc_datetime

    belongs_to :poet, TravelingPoet.Poets.Poet

    timestamps()
  end

  def dimensions, do: @dimensions
  def polarities, do: @polarities
  def sources, do: @sources

  @doc "Sources the user drove themselves — these may revive a dismissed row."
  def explicit_sources, do: ~w(tap settings)

  @doc false
  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [
      :poet_id,
      :key,
      :label,
      :dimension,
      :polarity,
      :source,
      :status,
      :weight,
      :evidence,
      :last_confirmed_at
    ])
    |> validate_required([:poet_id, :key, :label, :dimension, :polarity, :source])
    |> validate_inclusion(:dimension, @dimensions)
    |> validate_inclusion(:polarity, @polarities)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:label, max: 120)
    |> unique_constraint([:poet_id, :key])
  end
end
