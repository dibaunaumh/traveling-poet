defmodule TravelingPoet.ChangeStream.Endpoint do
  @moduledoc """
  A registered webhook receiver. Only `url` and `auth_token` are admin input;
  everything else (the signing secret, cursor, health counters, backfill
  state) is set by the stream itself via `Ecto.Changeset.change/2`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active paused failing)
  @backfill_statuses ~w(idle running done failed)

  schema "change_stream_endpoints" do
    field :url, :string
    field :auth_token, :string
    field :signing_secret, :string
    field :status, :string, default: "active"
    field :cursor_event_id, :integer, default: 0
    field :consecutive_failures, :integer, default: 0
    field :next_attempt_at, :utc_datetime
    field :last_success_at, :utc_datetime
    field :last_failure_at, :utc_datetime
    field :last_error, :string
    field :last_status_code, :integer
    field :backfill_status, :string, default: "idle"
    field :backfill_progress, :map, default: %{}
    field :backfill_error, :string
    field :backfilled_at, :utc_datetime

    timestamps()
  end

  def statuses, do: @statuses
  def backfill_statuses, do: @backfill_statuses

  @doc "Admin registration: url + the bearer token the receiver expects."
  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [:url, :auth_token])
    |> update_change(:url, &String.trim/1)
    |> update_change(:auth_token, &String.trim/1)
    |> validate_required([:url, :auth_token])
    |> validate_url()
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:backfill_status, @backfill_statuses)
  end

  # http/https with a host. Localhost is deliberately allowed — that is how
  # you point the stream at a receiver on the dev box.
  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      case URI.parse(url) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [url: "must be an http(s) URL"]
      end
    end)
  end
end
