defmodule TravelingPoet.Credits do
  @moduledoc """
  Per-user credit balance + append-only ledger — the monetization foundation.

  Phase 1 bills a flat rate per daily run by mission (wander = 1 credit,
  scout = 5). The app can't see the sprite→OpenRouter token stream today, so
  metered billing is a later data change (per-user OpenRouter keys, #1);
  the ledger stores milli-credits so that switch needs no migration.

  Chat turns and illustrations are bundled into the daily run — the daily
  `Usage` caps stay as abuse guards. `quota_exempt` users are free forever.
  """

  import Ecto.Query
  require Logger

  alias TravelingPoet.{Poets, Repo}
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Credits.CreditTransaction
  alias TravelingPoet.Poets.Poet

  @milli 1000

  # Credits per daily run, by mission.
  @default_rates %{"wander" => 1, "scout" => 5}

  @default_packs [
    %{id: "p10", credits: 10, cents: 500},
    %{id: "p50", credits: 50, cents: 2000},
    %{id: "p100", credits: 100, cents: 4000},
    %{id: "p300", credits: 300, cents: 10_000}
  ]

  # ---------------------------------------------------------------------------
  # Reads

  def balance(%User{credits_balance: b}), do: b || 0

  @doc "Milli-credits → display string: 10 → \"10\", 9500 → \"9.5\"."
  def format(milli) when is_integer(milli) do
    whole = div(milli, @milli)
    frac = rem(abs(milli), @milli)

    cond do
      frac == 0 -> Integer.to_string(whole)
      true -> :erlang.float_to_binary(milli / @milli, decimals: 1)
    end
  end

  def to_milli(credits) when is_integer(credits), do: credits * @milli

  def packs, do: Application.get_env(:traveling_poet, :credit_packs, @default_packs)

  def pack(id), do: Enum.find(packs(), &(&1.id == id))

  def signup_credits, do: Application.get_env(:traveling_poet, :signup_credits, 10)

  def low_credits_days, do: Application.get_env(:traveling_poet, :low_credits_days, 3)

  @doc "Milli-credits one daily run costs for this poet's mission."
  def daily_run_cost(poet) do
    mode = if poet, do: Poet.mode(poet), else: "wander"
    rates = Application.get_env(:traveling_poet, :credit_rates, @default_rates)
    to_milli(Map.get(rates, mode, Map.fetch!(@default_rates, "wander")))
  end

  def can_run?(%User{quota_exempt: true}, _poet), do: true
  def can_run?(%User{} = user, poet), do: balance(user) >= daily_run_cost(poet)

  @doc "Days of travel left at the poet's pace; nil when it doesn't apply (exempt)."
  def runway_days(%User{quota_exempt: true}, _poet), do: nil
  def runway_days(%User{} = user, poet), do: balance(user) / daily_run_cost(poet)

  def low?(%User{} = user, poet) do
    case runway_days(user, poet) do
      nil -> false
      days -> days < low_credits_days()
    end
  end

  def exhausted?(%User{quota_exempt: true}, _poet), do: false
  def exhausted?(%User{} = user, poet), do: not can_run?(user, poet)

  def list_transactions(%User{id: user_id}, limit \\ 10) do
    CreditTransaction
    |> where(user_id: ^user_id)
    |> order_by(desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Writes

  def grant_signup(%User{} = user) do
    apply(user, to_milli(signup_credits()), "grant_signup", reference: "signup:#{user.id}")
  end

  def grant_referral(%User{} = user, %User{} = referrer) do
    apply(user, to_milli(signup_credits()), "grant_referral",
      reference: "referral:#{referrer.id}:#{user.id}",
      metadata: %{"referrer_id" => referrer.id}
    )
  end

  @doc "Admin grant/adjustment in whole credits (may be negative)."
  def adjust(%User{} = user, credits, opts \\ []) when is_integer(credits) do
    kind = if credits >= 0, do: "grant_admin", else: "admin_adjust"
    apply(user, to_milli(credits), kind, opts)
  end

  @doc """
  Credits a purchased pack. `reference` (e.g. `"stripe:cs_..."`) makes webhook
  retries idempotent — a replay returns `{:ok, :duplicate}`.
  """
  def purchase(%User{} = user, pack_id, reference) do
    case pack(pack_id) do
      nil ->
        {:error, :unknown_pack}

      pack ->
        apply(user, to_milli(pack.credits), "purchase",
          reference: reference,
          metadata: %{"pack_id" => pack.id, "cents" => pack.cents}
        )
    end
  end

  @doc "Charges one daily run up front; `{:ok, :exempt}` for free users."
  def debit_daily_run(%User{quota_exempt: true}, _poet, _ref), do: {:ok, :exempt}

  def debit_daily_run(%User{} = user, poet, ref) do
    apply(user, -daily_run_cost(poet), "debit_daily_run",
      reference: "usage_event:#{ref}",
      metadata: %{"mode" => Poet.mode(poet)}
    )
  end

  @doc "Refunds the debit recorded for `ref` (failed run). No-op if none."
  def refund_daily_run(%User{} = user, ref) do
    debit_ref = "usage_event:#{ref}"

    case Repo.get_by(CreditTransaction,
           user_id: user.id,
           kind: "debit_daily_run",
           reference: debit_ref
         ) do
      nil ->
        {:ok, :nothing_to_refund}

      tx ->
        apply(user, -tx.amount, "refund", reference: "refund:" <> debit_ref)
    end
  end

  @doc """
  Applies a signed milli-credit movement inside one transaction: re-reads the
  user, refuses to go below zero, writes the ledger row with `balance_after`,
  updates the cached balance, then broadcasts `{:credits_updated, balance}`
  on `"user:<id>"`. Debits may raise a low-balance alert.
  """
  def apply(%User{id: user_id}, amount, kind, opts \\ []) when is_integer(amount) do
    reference = Keyword.get(opts, :reference)
    metadata = Keyword.get(opts, :metadata, %{})

    result =
      Repo.transaction(fn ->
        user = Repo.get!(User, user_id)
        new_balance = (user.credits_balance || 0) + amount

        if amount < 0 and new_balance < 0 do
          Repo.rollback(:insufficient_credits)
        end

        tx_result =
          %CreditTransaction{}
          |> CreditTransaction.changeset(%{
            user_id: user.id,
            amount: amount,
            kind: kind,
            balance_after: new_balance,
            reference: reference,
            metadata: metadata
          })
          |> Repo.insert()

        case tx_result do
          {:ok, tx} ->
            user = user |> User.changeset(%{credits_balance: new_balance}) |> Repo.update!()
            {tx, user}

          {:error, %Ecto.Changeset{errors: errors} = cs} ->
            if Keyword.has_key?(errors, :kind) and reference_conflict?(errors) do
              Repo.rollback(:duplicate)
            else
              Repo.rollback(cs)
            end
        end
      end)

    case result do
      {:ok, {tx, user}} ->
        Phoenix.PubSub.broadcast(
          TravelingPoet.PubSub,
          "user:#{user.id}",
          {:credits_updated, user.credits_balance}
        )

        if amount < 0, do: maybe_alert_low(user)
        {:ok, tx}

      {:error, :duplicate} ->
        {:ok, :duplicate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reference_conflict?(errors) do
    match?({_, [constraint: :unique, constraint_name: _]}, Keyword.get(errors, :kind))
  end

  # Once per 24h, when runway drops under the threshold (or hits zero), tell
  # the user's live views and the Telegram notifier.
  defp maybe_alert_low(%User{} = user) do
    poet = Poets.get_poet_by_user(user.id)

    if low?(user, poet) and not recently_notified?(user) do
      user
      |> User.changeset(%{
        low_credits_notified_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      msg = {:credits_low, user.id, balance(user)}
      Phoenix.PubSub.broadcast(TravelingPoet.PubSub, "user:#{user.id}", msg)
      Phoenix.PubSub.broadcast(TravelingPoet.PubSub, "credits:low", msg)
    end

    :ok
  end

  defp recently_notified?(%User{low_credits_notified_at: nil}), do: false

  defp recently_notified?(%User{low_credits_notified_at: at}) do
    DateTime.diff(DateTime.utc_now(), at, :hour) < 24
  end
end
