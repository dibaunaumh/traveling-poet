defmodule TravelingPoet.ChatVisibilityTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Chat

  test "system triggers stay out of the visible conversation, the poet's replies stay in" do
    user = user_fixture()

    # What the app sends on the user's behalf to start a ritual.
    {:ok, _} =
      Chat.create_message(%{
        user_id: user.id,
        role: "user",
        content: "/travel-and-journal",
        channel: "system"
      })

    {:ok, _} =
      Chat.create_message(%{
        user_id: user.id,
        role: "agent",
        content: "Today I walked to Sintra.",
        channel: "system"
      })

    {:ok, _} =
      Chat.create_message(%{user_id: user.id, role: "user", content: "hi", channel: "telegram"})

    contents = Chat.list_messages(user.id) |> Enum.map(& &1.content)

    refute "/travel-and-journal" in contents
    assert "Today I walked to Sintra." in contents
    assert "hi" in contents
  end
end
