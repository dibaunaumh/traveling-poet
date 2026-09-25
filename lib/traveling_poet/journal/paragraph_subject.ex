defmodule TravelingPoet.Journal.ParagraphSubject do
  @moduledoc """
  Where one paragraph of a published entry sits on the subject tree
  (`Guide.PlaceTopics`), set by `Guide.TopicTagging`. Keyed by the
  paragraph's text (`Journal.Paragraphs.key/1`), so a revision that leaves
  a paragraph alone keeps its row, and reading signals recorded against the
  key stay attached to the right subject. `topic` nil: classified, about no
  subject (mood, logistics). The excerpt is kept for review only.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "paragraph_subjects" do
    field :key, :string
    field :section_kind, :string
    field :excerpt, :string
    field :topic, :string
    field :second_topic, :string
    field :classified_at, :utc_datetime

    belongs_to :poet, TravelingPoet.Poets.Poet
    belongs_to :journal_entry, TravelingPoet.Journal.Entry

    timestamps()
  end

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :poet_id,
      :journal_entry_id,
      :key,
      :section_kind,
      :excerpt,
      :topic,
      :second_topic,
      :classified_at
    ])
    |> validate_required([:poet_id, :journal_entry_id, :key, :classified_at])
    |> TravelingPoet.Guide.PlaceTopics.drop_unknown_paths([:topic, :second_topic])
    |> unique_constraint([:journal_entry_id, :key])
  end
end
