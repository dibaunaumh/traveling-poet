defmodule TravelingPoet.AiC.Users do
  @moduledoc """
  Where each reader stands with the app, told to Alice-in-Context as plain
  facts. AiC draws its users as figures on stairs (prospect, signed up,
  started using, free-tier active, paid active, inactive) and works out the
  stair itself from these facts, so nothing here knows about stages:

    * a `state` snapshot per user: when they signed in, how far onboarding
      went, which notifications reach them, what they paid, when they were
      last seen. Sent again only when one of those changed (the event id is a
      digest of them, so a snapshot sent twice is one event);
    * one `seen` per user per UTC day they open the app (`seen/2`, from
      `Accounts.touch_last_seen/2`), which is how AiC counts active days;
    * the anonymous visitor counts (`Analytics`), as a snapshot of the app.

  A name and facts only: never the email, never anything a reader wrote. A
  visitor id lives one day and cannot be joined to the next, so the week's
  count is the sum of the days' (visitor-days), not distinct people.
  """

  import Ecto.Query

  alias TravelingPoet.{AiC, Analytics, Repo}
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Credits.CreditTransaction
  alias TravelingPoet.WebPush.Subscription

  @doc """
  Every user with their facts, as `{user, attrs}`. `attrs` keys are AiC's
  (`signed_in_at`, `onboarding_step`, `onboarded`, `notifications`,
  `paid_cents`, `last_seen_at`) and `email_notify`; a fact that went away is
  sent empty, not left out, since AiC merges a snapshot into what it knew.
  """
  def all do
    paid = paid_cents()
    push = MapSet.new(Repo.all(from s in Subscription, distinct: true, select: s.user_id))

    User
    |> order_by(:id)
    |> Repo.all()
    |> Enum.map(fn user ->
      {user, attrs(user, Map.get(paid, user.id, 0), MapSet.member?(push, user.id))}
    end)
  end

  @doc "A user's facts, given what they paid (cents) and whether a browser takes their pushes."
  def attrs(%User{} = user, paid_cents, push?) do
    %{
      "signed_in_at" => iso(user.inserted_at),
      "onboarding_step" =>
        if(user.onboarding_completed, do: "", else: user.onboarding_step || ""),
      "onboarded" => user.onboarding_completed == true,
      # The channels the reader set up. Email is on for everyone from the
      # start, so it is a fact of its own, not a sign of setting anything up.
      "notifications" =>
        Enum.filter([user.telegram_chat_id && "telegram", push? && "push"], & &1),
      "email_notify" => user.email_notify == true,
      "paid_cents" => paid_cents,
      "last_seen_at" => iso(user.last_seen_at)
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc """
  Sends the snapshots that changed since `sent` (`%{user_id => digest}`, kept
  by the scheduler between ticks; empty after a boot, when AiC drops the ones
  it already has by their ids) and the visitor counts, and returns the new
  map. Does nothing, and asks the database nothing, when AiC is not configured.
  """
  def announce(sent, now \\ DateTime.utc_now()) do
    if AliceInContext.enabled?() do
      users =
        Map.new(all(), fn {user, attrs} ->
          digest = digest(attrs)
          if Map.get(sent, user.id) != digest, do: snapshot(user, attrs, digest)
          {user.id, digest}
        end)

      {today, week} = visitors(now)
      key = {DateTime.to_date(now), today, week}
      if Map.get(sent, :visitors) != key, do: visitors_snapshot(today, week)
      Map.put(users, :visitors, key)
    else
      sent
    end
  end

  @doc "One user's snapshot."
  def snapshot(%User{} = user, attrs, digest \\ nil) do
    party = AiC.reader_party(user)

    AiC.emit(%{
      id: "evt_user_state_#{party.id}_#{digest || digest(attrs)}",
      type: "state",
      verb: "user_state",
      actor: AiC.system_party("accounts"),
      subjects: [party],
      hints: %{space: "organization", address: "Serve/outer/Users/#{party.id}"},
      privacy: "internal",
      metadata: %{attrs: attrs}
    })
  end

  @doc """
  The user opened the app today. `previous` is when they were last seen
  before this request: only the first time on a UTC day is sent (and the id
  is fixed per user and day, so a second one is dropped anyway).
  """
  def seen(%User{} = user, previous, now \\ DateTime.utc_now()) do
    today = DateTime.to_date(now)

    if previous == nil or to_date(previous) != today do
      party = AiC.reader_party(user)

      AiC.emit(%{
        id: "evt_seen_#{party.id}_#{today}",
        type: "activity",
        verb: "seen",
        actor: party,
        hints: %{space: "organization", address: "Serve/outer/Users/#{party.id}"},
        privacy: "internal",
        occurred_at: DateTime.to_iso8601(DateTime.truncate(now, :second))
      })
    else
      :skipped
    end
  end

  @doc "Distinct visitors today and the sum of the last seven days' (visitor-days)."
  def visitors(now \\ DateTime.utc_now()) do
    since = now |> DateTime.to_date() |> Date.add(-6) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    days = Analytics.daily_visitors(since)
    today = DateTime.to_date(now)

    {Enum.find_value(days, 0, fn {d, n} -> if d == today, do: n end),
     days |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
  end

  defp visitors_snapshot(today, week) do
    AiC.emit(%{
      id: "evt_visitors_#{Date.utc_today()}_#{today}_#{week}",
      type: "state",
      verb: "visitors",
      actor: AiC.system_party("analytics"),
      subjects: [%{kind: "app", id: "traveling-poet"}],
      hints: %{space: "organization", address: "Serve/outer/Users"},
      privacy: "internal",
      metadata: %{
        attrs: %{visitors_today: today, visitors_7d: week, visitors_7d_kind: "visitor-days"}
      }
    })
  end

  # What each user paid, in cents: the packs they bought, less any the store refunded.
  defp paid_cents do
    refunded =
      from r in CreditTransaction,
        where: r.kind == "purchase_refund" and not is_nil(r.reference),
        select: r.reference

    Repo.all(
      from p in CreditTransaction,
        where:
          p.kind == "purchase" and (is_nil(p.reference) or p.reference not in subquery(refunded)),
        select: {p.user_id, p.metadata}
    )
    |> Enum.reduce(%{}, fn {id, meta}, acc ->
      Map.update(acc, id, cents(meta), &(&1 + cents(meta)))
    end)
  end

  defp cents(%{"cents" => c}) when is_integer(c), do: c
  defp cents(_), do: 0

  defp digest(attrs) do
    :crypto.hash(:sha256, attrs |> Enum.sort() |> inspect())
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(DateTime.truncate(at, :second))
  defp iso(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> iso()

  defp to_date(%DateTime{} = at), do: DateTime.to_date(at)
  defp to_date(%NaiveDateTime{} = at), do: NaiveDateTime.to_date(at)
end
