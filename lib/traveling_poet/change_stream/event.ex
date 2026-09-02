defmodule TravelingPoet.ChangeStream.Event do
  @moduledoc """
  One row of the outbox. Written only by `Capture` via `insert_all`, read by
  `Delivery` from each endpoint's cursor. `payload` is the full redacted
  record for inserts/updates and `%{"id" => n}` for deletes — the row is gone,
  the id is all that is left to say.
  """

  use Ecto.Schema

  @actions ~w(insert update delete)

  schema "change_stream_events" do
    field :entity, :string
    field :row_id, :integer
    field :action, :string
    field :payload, :map
    field :occurred_at, :utc_datetime
  end

  def actions, do: @actions
end
