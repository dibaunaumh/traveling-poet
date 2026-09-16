defmodule TravelingPoet.Usage do
  @moduledoc """
  Per-user cost ledger + quota checks. Costs are estimates attributed
  app-side (per-kind cent estimates from config); good enough to enforce
  trial-phase caps before Stripe lands.
  """

  import Ecto.Query
  alias TravelingPoet.Repo
  alias TravelingPoet.Usage.UsageEvent
  alias TravelingPoet.Accounts.User

  # Default per-event cost estimates (cents); overridable in config.
  @default_costs %{
    "daily_run" => 15,
    "daily_run_attempt" => 0,
    # the run itself is what costs; the attempt marker is bookkeeping
    "first_entry_attempt" => 0,
    # a revision turn after feedback markers; not credit-billed, capped per day
    "marker_revision_attempt" => 0,
    # A book composition turn. Credit-billed, so zero here: the cents budget
    # also gates the daily run, and a book must never cost tomorrow's entry.
    "book_compose_attempt" => 0,
    "book_compose" => 0,
    "chat_turn" => 2,
    "image_gen" => 4,
    "exec" => 0,
    "tokens" => 0
  }

  def record(user_id, kind, attrs \\ %{}) do
    %UsageEvent{}
    |> UsageEvent.changeset(
      Map.merge(
        %{
          user_id: user_id,
          kind: kind,
          cost_cents_est: Map.get(attrs, :cost_cents_est, estimated_cost(kind)),
          occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        Map.take(attrs, [:tokens_in, :tokens_out, :metadata, :cost_cents_est])
      )
    )
    |> Repo.insert()
  end

  def estimated_cost(kind), do: Map.get(costs(), kind, 0)

  defp costs do
    Application.get_env(:traveling_poet, :usage_costs, @default_costs)
  end

  @doc "Total estimated cost (cents) for a user since UTC midnight today."
  def today_cost(user_id) do
    UsageEvent
    |> where(user_id: ^user_id)
    |> where([e], e.occurred_at >= ^start_of_today())
    |> select([e], coalesce(sum(e.cost_cents_est), 0))
    |> Repo.one()
  end

  @doc "Count of today's events of the given kind for a user."
  def today_count(user_id, kind) do
    UsageEvent
    |> where(user_id: ^user_id, kind: ^kind)
    |> where([e], e.occurred_at >= ^start_of_today())
    |> select([e], count(e.id))
    |> Repo.one()
  end

  @doc """
  Whether the user is within their daily budget and the per-kind cap for the
  operation they're about to perform.
  """
  def within_budget?(%User{quota_exempt: true}, _kind), do: true

  def within_budget?(%User{} = user, kind) do
    today_cost(user.id) < user.daily_budget_cents and today_count(user.id, kind) < cap(kind)
  end

  defp cap("daily_run"), do: Application.get_env(:traveling_poet, :daily_runs_cap, 1)
  defp cap("chat_turn"), do: Application.get_env(:traveling_poet, :daily_chat_turns_cap, 50)
  defp cap("image_gen"), do: Application.get_env(:traveling_poet, :daily_image_cap, 6)

  defp cap("marker_revision_attempt"),
    do: Application.get_env(:traveling_poet, :daily_marker_revisions_cap, 4)

  defp cap("book_compose_attempt"),
    do: Application.get_env(:traveling_poet, :daily_book_compose_cap, 2)

  defp cap(_), do: 1_000_000

  @doc "Usage rollup rows for the admin dashboard: {user, today, last 7 days}."
  def fleet_rollup do
    week_ago = DateTime.add(DateTime.utc_now(), -7, :day)

    UsageEvent
    |> where([e], e.occurred_at >= ^week_ago)
    |> group_by([e], e.user_id)
    |> select([e], %{
      user_id: e.user_id,
      week_cost: coalesce(sum(e.cost_cents_est), 0),
      events: count(e.id)
    })
    |> Repo.all()
  end

  defp start_of_today do
    DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end
end
