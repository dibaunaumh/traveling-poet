defmodule TravelingPoet.ChatVisibilityTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  import Ecto.Query

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

  test "two savers finishing the same reply at once keep one message" do
    user = user_fixture()
    reply = %{user_id: user.id, content: "Samual, I'm Ezra Halloway.", response_id: "r1"}

    results =
      1..4
      |> Enum.map(fn _ ->
        Task.async(fn -> TravelingPoet.Chat.create_agent_message_once(reply) end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, %TravelingPoet.Chat.ChatMessage{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:ok, :duplicate})) == 3

    assert TravelingPoet.Repo.aggregate(
             from(m in TravelingPoet.Chat.ChatMessage, where: m.user_id == ^user.id),
             :count
           ) == 1
  end
end
