defmodule TravelingPoet.Books.Pdf do
  @moduledoc """
  One PDF of the book, rendered on the poet's sprite.

  `rendering` while the sprite works, `ready` once the app has checked the
  uploaded file itself, `failed` otherwise, with the sprite's log tail kept
  for whoever looks into it. `variant` is "plain" (as written) or "composed"
  (with the edition's matter, `edition_id`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(rendering ready failed)
  @variants ~w(plain composed)
  @page_sizes ~w(a5 a4 letter)

  schema "book_pdfs" do
    field :variant, :string, default: "plain"
    field :page_size, :string, default: "a5"
    field :status, :string, default: "rendering"
    field :s3_key, :string
    field :byte_size, :integer
    field :pages, :integer
    field :error, :string
    field :log, :string
    field :rendered_at, :utc_datetime
    field :drive_status, :string
    field :drive_file_id, :string
    field :drive_web_link, :string
    field :drive_error, :string
    field :drive_saved_at, :utc_datetime

    belongs_to :poet, TravelingPoet.Poets.Poet
    belongs_to :edition, TravelingPoet.Books.Edition

    timestamps()
  end

  def page_sizes, do: @page_sizes

  @doc false
  def changeset(pdf, attrs) do
    pdf
    |> cast(attrs, [
      :poet_id,
      :edition_id,
      :variant,
      :page_size,
      :status,
      :s3_key,
      :byte_size,
      :pages,
      :error,
      :log,
      :rendered_at,
      :drive_status,
      :drive_file_id,
      :drive_web_link,
      :drive_error,
      :drive_saved_at
    ])
    |> validate_required([:poet_id, :variant, :page_size, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:variant, @variants)
    |> validate_inclusion(:page_size, @page_sizes)
    |> update_change(:error, &truncate(&1, 255))
    |> update_change(:log, &truncate(&1, 8000))
    |> update_change(:drive_error, &truncate(&1, 255))
    |> validate_inclusion(:drive_status, ~w(saving saved failed))
    |> foreign_key_constraint(:poet_id)
  end

  defp truncate(nil, _max), do: nil
  defp truncate(text, max), do: String.slice(text, -max, max)
end
