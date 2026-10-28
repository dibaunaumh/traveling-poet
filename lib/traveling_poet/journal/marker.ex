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

  The buttons under the main drawing (`drawing_kinds/0`) are markers on that
  illustration too, so a "Made up" travels to the poet the way a "Boring"
  does. Three of them belong to drawings only and stay out of the tray.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @tray_kinds ~w(interesting boring more_details drawing_needed link_needed beautiful not_creative other)
  @drawing_only ~w(meh inaccurate made_up)
  @kinds @tray_kinds ++ @drawing_only
  @drawing_kinds ~w(beautiful meh inaccurate made_up)
  # Praise asks the poet for nothing; every other kind asks for a change.
  @praise ~w(interesting beautiful)
  @targets ~w(text section illustration)
  @quote_max 500
  @context_max 64
  @note_max 500

  @specs %{
    "interesting" => %{
      label: "Interesting",
      meaning: "This held my attention",
      ask: "keep it exactly as it is, and do more like it in the days ahead"
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
      ask: "keep it exactly as it is"
    },
    "not_creative" => %{
      label: "Not creative enough",
      meaning: "This reads like anyone could have written it",
      ask: "rewrite it in your own voice from a fresh angle, same facts"
    },
    "meh" => %{
      label: "Meh",
      meaning: "This drawing does nothing for me",
      ask: "redraw it: the same place from a livelier moment or angle"
    },
    "inaccurate" => %{
      label: "Inaccurate",
      meaning: "This does not look like the real place",
      ask: "redraw it true to the real place: check every detail against your reference sources"
    },
    "made_up" => %{
      label: "Made up",
      meaning: "Something in this drawing could not exist",
      ask:
        "redraw it with nothing invented: only what the real place has, every structure whole and possible"
    },
    # Carries a free-text note; the digest quotes the note instead of `ask`.
    "other" => %{
      label: "Other feedback",
      meaning: "Something else I want to tell you about this",
      ask: "read what your companion wrote and act on it"
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
    field :note, :string
    field :sent_at, :utc_datetime

    belongs_to :journal_entry, TravelingPoet.Journal.Entry
    belongs_to :user, TravelingPoet.Accounts.User

    timestamps()
  end

  def kinds, do: @kinds

  @doc "The kinds the marker menu offers for text, sections and drawings."
  def tray_kinds, do: @tray_kinds

  @doc "The kinds of the buttons under the main drawing, in button order."
  def drawing_kinds, do: @drawing_kinds

  @doc "The kinds that ask for nothing to change."
  def praise_kinds, do: @praise
  def targets, do: @targets
  def quote_max, do: @quote_max
  def context_max, do: @context_max
  def note_max, do: @note_max

  @doc "`%{label:, meaning:, ask:}` for a kind; nil for an unknown one."
  def spec(kind), do: Map.get(@specs, kind)

  @doc "`[{kind, spec}]` in tray order."
  def specs, do: Enum.map(@tray_kinds, &{&1, spec(&1)})

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
      :note,
      :sent_at
    ])
    |> validate_required([:journal_entry_id, :user_id, :kind, :target])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:target, @targets)
    |> validate_inclusion(:section_kind, TravelingPoet.Journal.Section.kinds())
    |> validate_length(:quote, max: @quote_max)
    |> validate_length(:prefix, max: @context_max)
    |> validate_length(:suffix, max: @context_max)
    |> validate_length(:note, max: @note_max)
    |> validate_target()
  end

  defp validate_target(changeset) do
    target = get_field(changeset, :target)

    if get_field(changeset, :kind) in @drawing_only and target != "illustration",
      do: add_error(changeset, :kind, "is for drawings only"),
      else: validate_target(changeset, target)
  end

  defp validate_target(changeset, target) do
    case target do
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
