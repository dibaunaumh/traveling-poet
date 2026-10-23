defmodule TravelingPoet.ReferralsTest do
  use TravelingPoet.DataCase, async: false

  import Ecto.Query
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Credits, Referrals, Repo}
  alias TravelingPoet.Accounts.User

  # A reader as sign-up leaves them: the welcome credits already granted
  defp new_reader(attrs \\ %{}) do
    user = user_fixture(attrs)
    {:ok, _} = Credits.grant_signup(user)
    Accounts.get_user!(user.id)
  end

  defp balance(user), do: Credits.balance(Accounts.get_user!(user.id))

  test "a reader's code is made once, readable, and stays" do
    user = user_fixture()
    code = Referrals.code_for(user)

    assert code =~ ~r/^[A-HJ-KM-NP-Z2-9]{7}$/
    assert Referrals.code_for(Accounts.get_user!(user.id)) == code
    assert Referrals.referrer_by_code(String.downcase(code)).id == user.id
    assert Referrals.referrer_by_code(" #{code} ").id == user.id
  end

  test "normalize/1 takes what a reader might paste and refuses what cannot be a code" do
    assert Referrals.normalize(" abc-de2f ") == "ABCDE2F"
    assert Referrals.normalize("x") == nil
    assert Referrals.normalize("<script>") == nil
    assert Referrals.normalize(nil) == nil
  end

  test "a friend who joins through a code starts with 10 credits more than the welcome" do
    referrer = new_reader()
    friend = new_reader()
    assert balance(friend) == Credits.to_milli(10)

    assert {:ok, %User{id: id}} = Referrals.claim(friend, Referrals.code_for(referrer))
    assert id == referrer.id

    assert balance(friend) == Credits.to_milli(20)
    assert Accounts.get_user!(friend.id).referred_by_id == referrer.id
    # The referrer earns nothing yet: that waits for the friend's first page
    assert balance(referrer) == Credits.to_milli(10)
  end

  test "a code is claimed once, never one's own, and only by a new reader" do
    referrer = new_reader()
    other = new_reader()
    friend = new_reader()
    code = Referrals.code_for(referrer)

    assert {:error, :own_code} = Referrals.claim(referrer, code)
    assert {:error, :invalid_code} = Referrals.claim(friend, "ZZZZZZZ")

    assert {:ok, _} = Referrals.claim(friend, code)
    friend = Accounts.get_user!(friend.id)
    assert {:error, :not_eligible} = Referrals.claim(friend, Referrals.code_for(other))
    assert balance(friend) == Credits.to_milli(20)

    old = new_reader()
    eight_days_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -8 * 86_400)
    Repo.update_all(from(u in User, where: u.id == ^old.id), set: [inserted_at: eight_days_ago])
    old = Accounts.get_user!(old.id)

    refute Referrals.can_claim?(old)
    assert {:error, :not_eligible} = Referrals.claim(old, code)
  end

  test "the referrer is rewarded with the friend's first page, once, and hears about it" do
    referrer = new_reader()
    friend = new_reader()
    {:ok, _} = Referrals.claim(friend, Referrals.code_for(referrer))
    poet = poet_fixture(friend)

    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "referrals")

    published_entry_fixture(poet, %{entry_date: ~D[2026-10-20]})
    assert balance(referrer) == Credits.to_milli(20)
    assert_receive {:referral_rewarded, rid, fid}
    assert {rid, fid} == {referrer.id, friend.id}

    # A second page, and a revision of the first, earn nothing more
    second = published_entry_fixture(poet, %{entry_date: ~D[2026-10-21]})
    {:ok, _} = TravelingPoet.Journal.publish_entry(second)
    assert balance(referrer) == Credits.to_milli(20)
    refute_receive {:referral_rewarded, _, _}

    assert Referrals.stats(referrer) == %{joined: 1, rewarded: 1, earned: Credits.to_milli(10)}
    assert Referrals.summary() == %{joined: 1, referrers: 1, rewarded: 1}
  end

  test "a reader who came on their own rewards nobody" do
    reader = new_reader()
    poet = poet_fixture(reader)
    published_entry_fixture(poet)

    assert Referrals.after_publish(poet.id) == :none
  end

  test "a referrer's rewards stop at the cap" do
    Application.put_env(:traveling_poet, :referral_reward_cap, 1)
    on_exit(fn -> Application.delete_env(:traveling_poet, :referral_reward_cap) end)

    referrer = new_reader()
    code = Referrals.code_for(referrer)

    for date <- [~D[2026-10-20], ~D[2026-10-21]] do
      friend = new_reader()
      {:ok, _} = Referrals.claim(friend, code)
      published_entry_fixture(poet_fixture(friend), %{entry_date: date})
    end

    assert balance(referrer) == Credits.to_milli(20)
    assert Referrals.stats(referrer).joined == 2
  end

  test "the referrer's note names the friend by first name and the credits" do
    payload = TravelingPoet.WebPush.referral_payload(%User{id: 7, name: "Dana Levi"})
    assert payload.title == "Dana's poet has set out"
    assert payload.body =~ "10 credits are yours"
    assert payload.url == "/settings#invite"

    assert TravelingPoet.WebPush.referral_payload(%User{id: 8, name: nil}).title ==
             "Your friend's poet has set out"
  end
end
