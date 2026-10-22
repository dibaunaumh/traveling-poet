defmodule TravelingPoet.ChatHousekeepingTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Chat

  test "purge_housekeeping removes dreaming reports and keeps the poet's pages" do
    user = user_fixture()

    {:ok, report} =
      Chat.create_message(%{
        user_id: user.id,
        role: "agent",
        content:
          "Memory dreaming run complete. Consolidated the strongest signal into long-term memory."
      })

    {:ok, page} =
      Chat.create_message(%{
        user_id: user.id,
        role: "agent",
        content: "Day 5: the palace that dreams in colour."
      })

    assert %{found: 1, deleted: 0, users: [user.id]} == Chat.purge_housekeeping()
    assert Repo.get(Chat.ChatMessage, report.id)

    assert %{found: 1, deleted: 1} = Chat.purge_housekeeping(commit: true)
    refute Repo.get(Chat.ChatMessage, report.id)
    assert Repo.get(Chat.ChatMessage, page.id)
  end
end
