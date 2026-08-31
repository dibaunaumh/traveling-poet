defmodule TravelingPoet.PurgeTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Accounts.{Purge, User}
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.{Journal, Repo, Usage}

  defp populated_user do
    user = user_fixture(%{credits: 5})
    poet = poet_fixture(user, %{name: "Marta"})

    {:ok, entry} = Journal.upsert_entry(poet.id, Date.utc_today(), %{title: "A day"})
    {:ok, _} = Journal.publish_entry(entry)

    {:ok, _} =
      Journal.create_media(%{
        poet_id: poet.id,
        journal_entry_id: entry.id,
        s3_key: "media/#{poet.id}/illustration.png",
        content_type: "image/png",
        kind: "illustration",
        sources: %{"items" => [%{"url" => "https://example.com/photo", "label" => "ref"}]}
      })

    {:ok, _} = Usage.record(user.id, "daily_run")
    {:ok, _} = TravelingPoet.Chat.create_message(%{user_id: user.id, role: "user", content: "hi"})

    {user, poet, entry}
  end

  test "purging a user takes their poet, journal and ledger with it" do
    {user, poet, entry} = populated_user()

    assert {:ok, summary} = Purge.purge(user.id, user.email)
    assert summary.poet == "Marta"
    # the media row's key is collected for cleanup even where object storage
    # isn't configured (test, bare dev box) and the delete is skipped
    assert summary.media_total == 1

    refute Repo.get(User, user.id)
    refute Repo.get(Poet, poet.id)
    refute Repo.get(Journal.Entry, entry.id)
    assert Usage.today_count(user.id, "daily_run") == 0
  end

  test "a mistyped email deletes nothing" do
    {user, poet, _entry} = populated_user()

    assert Purge.purge(user.id, "someone-else@example.com") == {:error, :email_mismatch}
    assert Repo.get(User, user.id)
    assert Repo.get(Poet, poet.id)
  end

  test "confirmation ignores case and surrounding space" do
    {user, _poet, _entry} = populated_user()

    assert {:ok, _} = Purge.purge(user.id, "  #{String.upcase(user.email)} ")
    refute Repo.get(User, user.id)
  end

  test "purge_by_email is the console path; a missing user is an error, not a crash" do
    {user, _poet, _entry} = populated_user()

    assert Purge.purge_by_email("nobody@example.com") == {:error, :not_found}
    assert {:ok, _} = Purge.purge_by_email(user.email)
    refute Repo.get(User, user.id)
  end

  test "a user with no poet purges cleanly" do
    user = user_fixture()

    assert {:ok, summary} = Purge.purge(user.id, user.email)
    assert summary.poet == nil
    assert summary.media_total == 0
    refute Repo.get(User, user.id)
  end
end
