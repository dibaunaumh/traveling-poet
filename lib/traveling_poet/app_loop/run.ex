defmodule TravelingPoet.AppLoop.Run do
  @moduledoc "One shadow run of the app-side poet loop (`AppLoop.Shadow`)."

  use Ecto.Schema
  import Ecto.Changeset

  schema "app_loop_runs" do
    belongs_to :poet, TravelingPoet.Poets.Poet

    field :entry_date, :date
    field :mode, :string, default: "shadow"
    field :model, :string
    # published | unpublished | error | limit | no_input
    field :status, :string
    field :error, :string
    # title, teaser, sections, places, finds, quiz, media, actions
    field :page, :map
    # %{"items" => [%{"tool", "status", "ms", "error"}]}
    field :steps, :map
    field :model_calls, :integer, default: 0
    field :tool_calls, :integer, default: 0
    field :malformed_calls, :integer, default: 0
    field :tool_errors, :integer, default: 0
    field :tokens_in, :integer, default: 0
    field :tokens_out, :integer, default: 0
    field :cost, :float
    field :ms, :integer
    field :final_text, :string
    field :trigger, :string

    timestamps(type: :utc_datetime)
  end

  @fields ~w(poet_id entry_date mode model status error page steps model_calls tool_calls
             malformed_calls tool_errors tokens_in tokens_out cost ms final_text trigger)a

  def changeset(run, attrs) do
    run
    |> cast(attrs, @fields)
    |> validate_required([:poet_id, :entry_date, :status])
  end
end
