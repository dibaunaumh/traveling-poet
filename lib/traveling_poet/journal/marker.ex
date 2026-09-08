defmodule TravelingPoet.Journal.Marker do
  @moduledoc """
  One reader's note on one passage of a journal entry: a colored marker
  dropped on a snippet of text, a whole section, or an illustration.

  Anchored by quoted text (with a little context either side) rather than by
  section id, because sections are wiped and re-inserted every time the poet
  re-puts the entry. A marker whose quote no longer appears in the entry has
  simply been revised away.

  `spec/1` is the single source of truth for what each kind means and what it
  asks of the poet; the tray, the digest sent to the agent, and the entry
  endpoint all read from it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(interesting boring more_details drawing_needed link_needed beautiful not_creative)
  @targets ~w(text section illustration)
  @quote_max 500
  @context_max 64

  @specs %{
    "interesting" => %{
      label: "Interesting",
      meaning: "This held my attention",
      ask: "keep it, and lean into more like it"
    },
    "boring" => %{
      label: "Boring",
      meaning: "This passage lost me",
      ask: "cut it, or sharpen it into one concrete image"
    },
    "more_details" => %{
      label: "More details",
      meaning: "I wanted to know more here",
      ask: "research this and expand it with grounded, cited facts"
    },
    "drawing_needed" => %{
      label: "Drawing needed",
      meaning: "I wanted to see this",
      ask: "draw it from real reference sources and place the illustration beside this passage"
    },
    "link_needed" => %{
      label: "Link needed",
      meaning: "I wanted somewhere to go from here",
      ask: "find the real page for this and add it as the section's source link"
    },
    "beautiful" => %{
      label: "Beautiful",
      meaning: "This moved me",
      ask: "keep it exactly as it is, and let the rest rise to it"
    },
    "not_creative" => %{
      label: "Not creative enough",
      meaning: "This reads like anyone could have written it",
      ask: "rewrite it in your own voice from a fresh angle, same facts"
    }
  }

  schema "entry_markers" do
    field :kind, :string
    field :target, :string
    field :section_kind, :string
    field :section_position, :integer
    field :media_id, :integer
    field :quote, :string
    field :prefix, :string
    field :suffix, :string
    field :sent_at, :utc_datetime

    belongs_to :journal_entry, TravelingPoet.Journal.Entry
    belongs_to :user, TravelingPoet.Accounts.User

    timestamps()
  end

  def kinds, do: @kinds
  def targets, do: @targets
  def quote_max, do: @quote_max
  def context_max, do: @context_max

  @doc "`%{label:, meaning:, ask:}` for a kind; nil for an unknown one."
  def spec(kind), do: Map.get(@specs, kind)

  @doc "`[{kind, spec}]` in tray order."
  def specs, do: Enum.map(@kinds, &{&1, spec(&1)})

  def label(kind), do: (spec(kind) || %{label: kind}).label

  @doc false
  def changeset(marker, attrs) do
    marker
    |> cast(attrs, [
      :journal_entry_id,
      :user_id,
      :kind,
      :target,
      :section_kind,
      :section_position,
      :media_id,
      :quote,
      :prefix,
      :suffix,
      :sent_at
    ])
    |> validate_required([:journal_entry_id, :user_id, :kind, :target])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:target, @targets)
    |> validate_inclusion(:section_kind, TravelingPoet.Journal.Section.kinds())
    |> validate_length(:quote, max: @quote_max)
    |> validate_length(:prefix, max: @context_max)
    |> validate_length(:suffix, max: @context_max)
    |> validate_target()
  end

  defp validate_target(changeset) do
    case get_field(changeset, :target) do
      "text" ->
        if blank?(get_field(changeset, :quote)),
          do: add_error(changeset, :quote, "is required for a text marker"),
          else: changeset

      "illustration" ->
        if is_nil(get_field(changeset, :media_id)),
          do: add_error(changeset, :media_id, "is required for an illustration marker"),
          else: changeset

      _ ->
        changeset
    end
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
end
