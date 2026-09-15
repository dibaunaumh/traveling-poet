defmodule TravelingPoet.Topics.Excursion do
  @moduledoc """
  One day off the road into a topic: a conference, a festival, a lab, a
  company, read from where the poet sits. Queue and log in one row.

  `status`: "queued" (asked for in chat, not yet taken), "written" (today's
  entry is linked), "published", "skipped". `source`: "app" when the cadence
  scheduled it, "chat" when the companion asked. `scheduled_for` is the
  entry's date once written; the decision rules read it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(queued written published skipped)
  @sources ~w(app chat)

  schema "topic_excursions" do
    field :status, :string, default: "queued"
    field :source, :string, default: "app"
    field :requested_venue, :string
    field :requested_url, :string
    field :scheduled_for, :date
    field :venue_name, :string
    field :venue_url, :string

    belongs_to :poet, TravelingPoet.Poets.Poet
    belongs_to :topic, TravelingPoet.Topics.Topic
    belongs_to :journal_entry, TravelingPoet.Journal.Entry

    timestamps()
  end

  def statuses, do: @statuses
  def sources, do: @sources

  @doc false
  def changeset(excursion, attrs) do
    excursion
    |> cast(attrs, [
      :poet_id,
      :topic_id,
      :journal_entry_id,
      :status,
      :source,
      :requested_venue,
      :requested_url,
      :scheduled_for,
      :venue_name,
      :venue_url
    ])
    |> update_change(:requested_venue, &trim/1)
    |> update_change(:venue_name, &trim/1)
    |> validate_required([:poet_id, :topic_id, :status, :source])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:requested_venue, max: 160)
    |> validate_length(:venue_name, max: 160)
    |> unique_constraint(:journal_entry_id)
  end

  defp trim(nil), do: nil
  defp trim(text), do: String.trim(text)
end
