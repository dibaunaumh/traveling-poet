defmodule TravelingPoet.Preferences.EntryPrompt do
  @moduledoc """
  The one question asked under a journal entry, and what the reader did with
  it. Answers and dismissals both matter: an ignored prompt is the signal that
  tells the cadence policy to back off.

  `options` follows the repo's `%{"items" => [...]}` convention (see
  `media.sources`, `poet.currently_reading`); each item is
  `%{"id", "label", "key", "dimension", "polarity"}`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @sources ~w(agent app)

  schema "entry_prompts" do
    field :question, :string
    field :options, :map, default: %{"items" => []}
    field :source, :string
    field :answered_at, :utc_datetime
    field :answer_option_id, :string
    field :dismissed_at, :utc_datetime

    belongs_to :journal_entry, TravelingPoet.Journal.Entry

    timestamps()
  end

  def sources, do: @sources

  def items(%__MODULE__{options: options}), do: Map.get(options || %{}, "items", [])
  def items(_), do: []

  @doc "The chosen option, or nil when unanswered (or when there is no prompt)."
  def answered_option(nil), do: nil
  def answered_option(%__MODULE__{answer_option_id: nil}), do: nil

  def answered_option(%__MODULE__{answer_option_id: id} = prompt) do
    Enum.find(items(prompt), &(&1["id"] == id))
  end

  @doc false
  def changeset(prompt, attrs) do
    prompt
    |> cast(attrs, [
      :journal_entry_id,
      :question,
      :options,
      :source,
      :answered_at,
      :answer_option_id,
      :dismissed_at
    ])
    |> validate_required([:journal_entry_id, :question, :source])
    |> validate_inclusion(:source, @sources)
    |> validate_length(:question, max: 200)
    |> unique_constraint(:journal_entry_id)
  end
end
