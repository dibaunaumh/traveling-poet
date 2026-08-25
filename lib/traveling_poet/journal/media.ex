defmodule TravelingPoet.Journal.Media do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(illustration poet_avatar)

  schema "media" do
    field :s3_key, :string
    field :content_type, :string
    field :byte_size, :integer
    field :kind, :string
    field :alt_text, :string
    field :prompt, :string
    # %{"items" => [%{"url" => ..., "label" => ...}]} — the original photos
    # the illustration was drawn from; rendered as outbound links only
    field :sources, :map, default: %{"items" => []}

    belongs_to :poet, TravelingPoet.Poets.Poet
    belongs_to :journal_entry, TravelingPoet.Journal.Entry

    timestamps()
  end

  def kinds, do: @kinds

  @doc false
  def changeset(media, attrs) do
    media
    |> cast(attrs, [
      :poet_id,
      :journal_entry_id,
      :s3_key,
      :content_type,
      :byte_size,
      :kind,
      :alt_text,
      :prompt,
      :sources
    ])
    |> validate_required([:poet_id, :s3_key, :content_type, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_sources()
  end

  # Illustrations must cite the real photos they were drawn from.
  defp validate_sources(changeset) do
    kind = get_field(changeset, :kind)
    items = get_field(changeset, :sources) |> Kernel.||(%{}) |> Map.get("items", [])

    cond do
      kind != "illustration" ->
        changeset

      items == [] ->
        add_error(changeset, :sources, "illustrations must include at least one source link")

      Enum.all?(items, &valid_source?/1) ->
        changeset

      true ->
        add_error(changeset, :sources, "each source needs an http(s) url")
    end
  end

  defp valid_source?(%{"url" => url}) when is_binary(url) do
    String.starts_with?(url, "http://") or String.starts_with?(url, "https://")
  end

  defp valid_source?(_), do: false

  def source_items(%__MODULE__{sources: sources}) do
    Map.get(sources || %{}, "items", [])
  end
end
