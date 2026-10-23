defmodule TravelingPoet.Referrals do
  @moduledoc """
  Referral credits (card-126, dec-015): a reader invites a friend, the friend
  starts with `referral_credits/0` more than the welcome grant, and the
  reader gets the same once the friend's poet publishes its first page.

  Rewarding the referrer on the friend's first page, not their sign-up, is
  the anti-abuse rule: a throwaway account earns nothing until a poet has
  actually set out for it. Both grants are ledger rows keyed on the friend
  (`referral:friend:<id>`, `referral:referrer:<id>`), so neither can land
  twice whatever retries or repeated publishes happen.

  How a friend arrives with a code: `/i/:code`, or `?ref=` on any page an
  owner shared (`TravelingPoetWeb.Plugs.Referral` parks it in the session),
  and `UserAuth.log_in_user/2` claims it on the way in. The iOS app loses the
  link at install, so the code can also be typed in Settings during the
  first `@claim_window_days`.
  """

  import Ecto.Query
  require Logger

  alias TravelingPoet.{Credits, Repo}
  alias TravelingPoet.Accounts.User

  # No 0/O, 1/I/L: a code is read off a screen and typed on a phone.
  @alphabet ~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  @code_length 7
  @claim_window_days 7

  @doc "Credits each side gets: the friend at sign-up, the referrer at the friend's first page."
  def referral_credits, do: Application.get_env(:traveling_poet, :referral_credits, 10)

  @doc """
  Referrer rewards one reader can collect, all friends together. A guard
  against farming, set well above what anyone inviting real friends reaches.
  """
  def reward_cap, do: Application.get_env(:traveling_poet, :referral_reward_cap, 25)

  @doc "The reader's invite code, made and stored the first time it is asked for."
  def code_for(%User{referral_code: code}) when is_binary(code), do: code

  def code_for(%User{} = user) do
    code = generate_code()

    case user |> User.changeset(%{referral_code: code}) |> Repo.update() do
      {:ok, %{referral_code: code}} ->
        code

      # Another reader holds this code (a 1 in 27 billion draw), or a second
      # tab stored one first: read back what is there and try again if empty.
      {:error, _} ->
        case Repo.get(User, user.id) do
          %{referral_code: code} when is_binary(code) -> code
          fresh -> code_for(fresh)
        end
    end
  end

  defp generate_code do
    for _ <- 1..@code_length, into: "", do: <<Enum.random(@alphabet)>>
  end

  @doc """
  A code as a reader might type or paste it, upper-cased and stripped, or nil
  when it cannot be one. Pure, so the plug can use it on every request.
  """
  def normalize(code) when is_binary(code) do
    code = code |> String.trim() |> String.upcase() |> String.replace(~r/[\s-]/, "")
    if code =~ ~r/^[A-Z0-9]{5,12}$/, do: code
  end

  def normalize(_), do: nil

  @doc "The reader a code belongs to, or nil."
  def referrer_by_code(code) do
    case normalize(code) do
      nil -> nil
      code -> Repo.get_by(User, referral_code: code)
    end
  end

  @doc """
  Whether a reader can still be credited to a friend: no referrer yet, and an
  account younger than #{@claim_window_days} days.
  """
  def can_claim?(%User{referred_by_id: nil, inserted_at: %NaiveDateTime{} = at}) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), at, :day) < @claim_window_days
  end

  def can_claim?(_), do: false

  @doc """
  Credits `user` to the reader behind `code` and grants the friend's bonus.

  `{:ok, referrer}`, or `{:error, reason}`: `:invalid_code`, `:not_eligible`
  (already referred, or past the window), `:own_code`.
  """
  def claim(%User{} = user, code) do
    referrer = referrer_by_code(code)

    cond do
      is_nil(referrer) -> {:error, :invalid_code}
      referrer.id == user.id -> {:error, :own_code}
      not can_claim?(user) -> {:error, :not_eligible}
      true -> do_claim(user, referrer)
    end
  end

  defp do_claim(user, referrer) do
    # Only a reader with no referrer yet is updated, so two sign-ins racing
    # with two codes cannot both win.
    {updated, _} =
      from(u in User, where: u.id == ^user.id and is_nil(u.referred_by_id))
      |> Repo.update_all(set: [referred_by_id: referrer.id])

    if updated == 1 do
      {:ok, _} =
        Credits.grant_referral(user, referrer, :friend, Credits.to_milli(referral_credits()))

      Logger.info("Referrals: user #{user.id} joined through user #{referrer.id}")
      {:ok, referrer}
    else
      {:error, :not_eligible}
    end
  end

  @doc """
  Called on every first publish (`Journal.publish_entry/1`): when the poet's
  owner came through a friend, that friend gets their reward and a note.
  Idempotent on the ledger reference, so a second page grants nothing.
  Returns `{:ok, referrer}` when it granted, otherwise `:none`.
  """
  def reward_referrer(%User{referred_by_id: nil}), do: :none

  def reward_referrer(%User{referred_by_id: referrer_id} = friend) do
    with %User{} = referrer <- Repo.get(User, referrer_id),
         true <- rewards_collected(referrer) < reward_cap(),
         {:ok, %Credits.CreditTransaction{}} <-
           Credits.grant_referral(
             friend,
             referrer,
             :referrer,
             Credits.to_milli(referral_credits())
           ) do
      Logger.info("Referrals: user #{referrer.id} rewarded for user #{friend.id}'s first page")
      {:ok, referrer}
    else
      _ -> :none
    end
  end

  def reward_referrer(_), do: :none

  @doc """
  `reward_referrer/1` for the owner of `poet_id`, and on a grant the news on
  `"referrals"` for the notifiers: `{:referral_rewarded, referrer_id, friend_id}`.
  """
  def after_publish(poet_id) do
    with %{user_id: user_id} <- TravelingPoet.Poets.get_poet(poet_id),
         %User{} = friend <- Repo.get(User, user_id),
         {:ok, referrer} <- reward_referrer(friend) do
      Phoenix.PubSub.broadcast(
        TravelingPoet.PubSub,
        "referrals",
        {:referral_rewarded, referrer.id, friend.id}
      )

      {:ok, referrer}
    else
      _ -> :none
    end
  end

  defp rewards_collected(%User{id: id}) do
    from(t in Credits.CreditTransaction,
      where:
        t.user_id == ^id and t.kind == "grant_referral" and
          like(t.reference, "referral:referrer:%")
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  What Settings shows a reader about their invites: friends who joined, how
  many of their poets have set out, and the credits earned for them.
  """
  def stats(%User{id: id}) do
    joined = from(u in User, where: u.referred_by_id == ^id) |> Repo.aggregate(:count)

    earned =
      from(t in Credits.CreditTransaction,
        where:
          t.user_id == ^id and t.kind == "grant_referral" and
            like(t.reference, "referral:referrer:%"),
        select: {count(t.id), coalesce(sum(t.amount), 0)}
      )
      |> Repo.one()

    {rewarded, milli} = earned
    %{joined: joined, rewarded: rewarded, earned: milli}
  end

  @doc """
  Fleet totals for the monthly review in the marketing plan: readers who
  joined through a friend, how many of their poets set out, how many
  readers have invited anyone. Called over `rpc`.
  """
  def summary do
    joined = from(u in User, where: not is_nil(u.referred_by_id)) |> Repo.aggregate(:count)

    referrers =
      from(u in User,
        where: not is_nil(u.referred_by_id),
        select: count(u.referred_by_id, :distinct)
      )
      |> Repo.one()

    rewarded =
      from(t in Credits.CreditTransaction,
        where: t.kind == "grant_referral" and like(t.reference, "referral:referrer:%")
      )
      |> Repo.aggregate(:count)

    %{joined: joined, referrers: referrers, rewarded: rewarded}
  end
end
