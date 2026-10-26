defmodule TravelingPoet.Feedback.Message do
  @moduledoc """
  One note from a reader about the app (card-137): something broken,
  something they would change, something missing. A visitor who is not
  signed in leaves an email address instead of a user (card-63). `page` is
  where they were when they wrote it, `client` the web or the iOS app.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(broken change missing other)
  @statuses ~w(new done)
  @body_max 4000

  schema "feedback_messages" do
    field :email, :string
    field :kind, :string
    field :body, :string
    field :page, :string
    field :client, :string
    field :status, :string, default: "new"

    belongs_to :user, TravelingPoet.Accounts.User

    timestamps()
  end

  def kinds, do: @kinds
  def body_max, do: @body_max

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:user_id, :email, :kind, :body, :page, :client])
    |> update_change(:body, &String.trim/1)
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:kind, :body])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:body, max: @body_max)
    |> validate_length(:page, max: 255)
    |> validate_sender()
  end

  def status_changeset(message, status) do
    message |> change(status: status) |> validate_inclusion(:status, @statuses)
  end

  # A signed-in reader is known; anyone else must leave a way to answer them
  defp validate_sender(changeset) do
    if get_field(changeset, :user_id) do
      changeset
    else
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
      |> validate_length(:email, max: 160)
    end
  end
end
