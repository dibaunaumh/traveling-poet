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

  # A composed book edition: one long agent turn that reads the whole journey
  # and writes the front and back matter. Priced by the journey's size, capped.
  @default_book_compose %{base: 2, per_chapter: 1, max: 10}

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

  @doc """
  Milli-credits one daily run costs for this poet's mission. `scouting: true`
  prices the run as a scout's: a wanderer scouting a planned trip pays the
  scout rate on those days.
  """
  def daily_run_cost(poet, opts \\ []) do
    rates = Application.get_env(:traveling_poet, :credit_rates, @default_rates)
    to_milli(Map.get(rates, rate_mode(poet, opts), Map.fetch!(@default_rates, "wander")))
  end

  defp rate_mode(_poet, scouting: true), do: "scout"
  defp rate_mode(nil, _opts), do: "wander"
  defp rate_mode(poet, opts), do: if(opts[:scouting], do: "scout", else: Poet.mode(poet))

  @doc """
  Milli-credits a composed book edition costs for a journey of `chapters`
  stays: a base, plus one step per chapter (the poet writes an opener for
  each), never more than the cap.
  """
  def book_compose_cost(chapters) when is_integer(chapters) do
    rates = Application.get_env(:traveling_poet, :book_compose_credits, @default_book_compose)
    base = Map.get(rates, :base, @default_book_compose.base)
    per = Map.get(rates, :per_chapter, @default_book_compose.per_chapter)
    max = Map.get(rates, :max, @default_book_compose.max)

    to_milli(min(base + per * max(chapters, 0), max))
  end

  @doc "Whether this account can pay for a composition of that cost."
  def can_afford?(%User{quota_exempt: true}, _milli), do: true
  def can_afford?(%User{} = user, milli) when is_integer(milli), do: balance(user) >= milli

  def can_run?(user, poet, opts \\ [])
  def can_run?(%User{quota_exempt: true}, _poet, _opts), do: true
  def can_run?(%User{} = user, poet, opts), do: balance(user) >= daily_run_cost(poet, opts)

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
  def purchase(%User{} = user, pack_id, reference, metadata \\ %{}) do
    case pack(pack_id) do
      nil ->
        {:error, :unknown_pack}

      pack ->
        apply(user, to_milli(pack.credits), "purchase",
          reference: reference,
          metadata: Map.merge(metadata, %{"pack_id" => pack.id, "cents" => pack.cents})
        )
    end
  end

  @doc """
  Takes back a purchase the store refunded (`reference` is the purchase's
  own, e.g. `"apple:2000000123"`). Idempotent on that reference.

  The ledger never goes below zero, and by the time a refund arrives the
  credits may be spent, so this takes what is left of them, up to the pack,
  and writes the rest down as a shortfall, which pages the admins: whether
  to chase it is a person's call.
  """
  def reverse_purchase(reference, metadata \\ %{}) when is_binary(reference) do
    case Repo.get_by(CreditTransaction, kind: "purchase", reference: reference) do
      nil ->
        {:error, :unknown_purchase}

      %CreditTransaction{} = purchase ->
        user = Repo.get!(User, purchase.user_id)
        take = min(purchase.amount, max(user.credits_balance || 0, 0))
        shortfall = purchase.amount - take

        result =
          apply(user, -take, "purchase_refund",
            reference: reference,
            metadata:
              Map.merge(metadata, %{"purchased" => purchase.amount, "shortfall" => shortfall})
          )

        with {:ok, %CreditTransaction{}} <- result, true <- shortfall > 0 do
          TravelingPoet.Alerts.notify_admins(
            "A refunded credit pack was already partly spent: user #{user.id}, " <>
              "#{format(shortfall)} of #{format(purchase.amount)} credits could not be taken back (#{reference})."
          )
        end

        result
    end
  end

  @doc "Charges one daily run up front; `{:ok, :exempt}` for free users."
  def debit_daily_run(user, poet, ref, opts \\ [])

  def debit_daily_run(%User{quota_exempt: true}, _poet, _ref, _opts), do: {:ok, :exempt}

  # `day:` (move | stay | excursion) is recorded so the ledger says what kind
  # of run was bought, and `scouting:` prices a trip day at the scout rate
  # (`mode` is the rate paid, `mission` the poet's own when they differ). An
  # excursion costs the same as any run of this mode and runs on the poet's
  # own model; revisit once real ones show their cost.
  def debit_daily_run(%User{} = user, poet, ref, opts) do
    rate = rate_mode(poet, opts)

    metadata =
      %{"mode" => rate}
      |> then(&if(opts[:day], do: Map.put(&1, "day", opts[:day]), else: &1))
      |> then(&if(rate != Poet.mode(poet), do: Map.put(&1, "mission", Poet.mode(poet)), else: &1))

    apply(user, -daily_run_cost(poet, opts), "debit_daily_run",
      reference: "usage_event:#{ref}",
      metadata: metadata
    )
  end

  @doc "Refunds the debit recorded for `ref` (failed run). No-op if none."
  def refund_daily_run(%User{} = user, ref),
    do: refund_debit(user, "debit_daily_run", "usage_event:#{ref}")

  @doc "Whether the debit for this attempt was already refunded."
  def refunded_daily_run?(user_id, ref) do
    Repo.exists?(
      from(t in CreditTransaction,
        where:
          t.user_id == ^user_id and t.kind == "refund" and
            t.reference == ^"refund:usage_event:#{ref}"
      )
    )
  end

  @doc """
  Charges a composed book edition up front; `{:ok, :exempt}` for free
  accounts. The reference is the edition, so a retried request can never be
  charged twice.
  """
  def debit_book_compose(user, edition_id, milli, chapters)

  def debit_book_compose(%User{quota_exempt: true}, _edition_id, _milli, _chapters),
    do: {:ok, :exempt}

  def debit_book_compose(%User{} = user, edition_id, milli, chapters) do
    apply(user, -milli, "debit_book_compose",
      reference: "book_compose:#{edition_id}",
      metadata: %{"edition_id" => edition_id, "chapters" => chapters}
    )
  end

  @doc "Refunds a composition that did not land. No-op if it was never charged."
  def refund_book_compose(%User{} = user, edition_id),
    do: refund_debit(user, "debit_book_compose", "book_compose:#{edition_id}")

  # One refund per debit: the refund's own reference is derived from the
  # debit's, so a second refund of the same debit is a ledger duplicate.
  defp refund_debit(%User{} = user, kind, debit_ref) do
    case Repo.get_by(CreditTransaction, user_id: user.id, kind: kind, reference: debit_ref) do
      nil -> {:ok, :nothing_to_refund}
      tx -> apply(user, -tx.amount, "refund", reference: "refund:" <> debit_ref)
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
