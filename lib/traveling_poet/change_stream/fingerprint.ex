defmodule TravelingPoet.ChangeStream.Fingerprint do
  @moduledoc false

  use Ecto.Schema

  schema "change_stream_fingerprints" do
    field :entity, :string
    field :row_id, :integer
    field :fingerprint, :string
  end
end
