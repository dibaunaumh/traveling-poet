defmodule TravelingPoet.ChatTurnTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Chat, ChatTurn, Provisioner}

  setup do
    Application.put_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClientRecorder)
    Application.put_env(:traveling_poet, :sprites_client_listener, self())

    on_exit(fn ->
      Application.delete_env(:traveling_poet, :sprites_client)
      Application.delete_env(:traveling_poet, :sprites_client_listener)
    end)

    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "chat")
    user = agent_user_fixture(%{sprite_name: "sprite-chat-turn"})
    _poet = poet_fixture(user)
    %{user: user}
  end

  # The test process stands in for the gateway socket: the turn subscribes
  # to it, and the test sends it the socket's events.
  defp watch(user) do
    {:ok, pid} = ChatTurn.watch(user, socket: self())
    Ecto.Adapters.SQL.Sandbox.allow(TravelingPoet.Repo, self(), pid)
    ref = Process.monitor(pid)
    {pid, ref}
  end

  defp agent_replies(user), do: Chat.list_messages(user.id) |> Enum.filter(&(&1.role == "agent"))

  test "a reply that lands after the reader left is saved, the sprite held meanwhile, and the reader told",
       %{user: user} do
    {pid, ref} = watch(user)

    # held awake from the start of the turn
    assert_receive {:sprites_exec, "sprite-chat-turn", command}
    assert command =~ "tpoet-reply-"

    send(pid, {:gateway_event, {:text_delta, "Phuket first, "}})
    send(pid, {:gateway_event, {:text_delta, "four nights."}})
    send(pid, {:gateway_event, {:done, "r1"}})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert [%{content: "Phuket first, four nights."} = reply] = agent_replies(user)
    reply_id = reply.id
    user_id = user.id
    assert_receive {:poet_replied, ^user_id, ^reply_id}

    # and let go when it ends
    assert_receive {:sprites_exec, "sprite-chat-turn", release}
    assert release =~ "DELETE"
  end

  test "with the journal open the panel shows the reply; nobody is notified", %{user: user} do
    {:ok, _} = ChatTurn.reader_present(user.id)
    {pid, ref} = watch(user)

    send(pid, {:gateway_event, {:text_replace, "Here is your route."}})
    send(pid, {:gateway_event, {:done, "chat-history"}})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert [%{content: "Here is your route."}] = agent_replies(user)
    refute_received {:poet_replied, _, _}
  end

  test "a second message keeps the watch until its own reply", %{user: user} do
    {pid, ref} = watch(user)
    assert {:ok, ^pid} = ChatTurn.watch(user, socket: self())

    send(pid, {:gateway_event, {:text_delta, "One."}})
    send(pid, {:gateway_event, {:done, "r1"}})
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 50

    send(pid, {:gateway_event, {:text_delta, "Two."}})
    send(pid, {:gateway_event, {:done, "r2"}})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert Enum.map(agent_replies(user), & &1.content) == ["One.", "Two."]
  end

  test "a message the gateway turned away started nothing to wait for", %{user: user} do
    {pid, ref} = watch(user)
    send(pid, {:gateway_event, {:error, "Chat error"}})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert agent_replies(user) == []
  end

  test "a heartbeat acknowledgement is not the reply", %{user: user} do
    {pid, ref} = watch(user)
    send(pid, {:gateway_event, {:text_delta, "HEARTBEAT_OK"}})
    send(pid, {:gateway_event, {:done, "hb"}})
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 50

    send(pid, {:gateway_event, {:text_delta, "Real answer."}})
    send(pid, {:gateway_event, {:done, "r1"}})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert [%{content: "Real answer."}] = agent_replies(user)
  end

  test "the panel and the turn save one reply between them", %{user: user} do
    {:ok, _} = ChatTurn.reader_present(user.id)
    {pid, ref} = watch(user)

    {:ok, %Chat.ChatMessage{}} =
      Chat.create_agent_message_once(%{user_id: user.id, content: "Same words."})

    send(pid, {:gateway_event, {:text_delta, "Same words."}})
    send(pid, {:gateway_event, {:done, "r1"}})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert [%{content: "Same words."}] = agent_replies(user)
  end

  describe "the reader's notes" do
    test "the push title names the poet, the body is the start of the answer as plain text" do
      poet = %{name: "Tal"}
      long = "**Day one:** Phuket. " <> String.duplicate("Beaches and markets. ", 20)
      payload = TravelingPoet.WebPush.reply_payload(poet, %{id: 7, content: long})

      assert payload.title == "Tal answered you"
      assert payload.url == "/journal?chat=1"
      assert String.starts_with?(payload.body, "Day one: Phuket.")
      assert String.length(payload.body) <= 141
      assert String.ends_with?(payload.body, "…")

      he =
        TravelingPoet.Locale.with_locale("he", fn ->
          TravelingPoet.WebPush.reply_payload(poet, %{id: 7, content: "שלום"})
        end)

      assert he.title == "תשובה מ-Tal"
    end

    test "Telegram gets the answer itself, signed, so a reply there carries on" do
      text =
        TravelingPoet.Telegram.Notifier.reply_text(%{name: "Tal"}, %{content: "Phuket first."})

      assert text == "Phuket first.\n\n(Tal. Just reply here.)"
    end
  end

  describe "repack for a new mission" do
    test "waits out a running turn, then updates the workspace", %{user: user} do
      parent = self()
      {:ok, busy} = Agent.start_link(fn -> 2 end)

      busy? = fn _ -> Agent.get_and_update(busy, &{&1 > 0, &1 - 1}) end
      upgrade = fn u -> send(parent, {:upgraded, u.id}) && {:ok, u.sprite_name} end

      assert {:ok, "sprite-chat-turn"} =
               Provisioner.repack(user, busy?: busy?, upgrade: upgrade, wait_ms: 1)

      assert_received {:upgraded, _}
      # asked three times: busy, busy, free
      assert Agent.get(busy, & &1) == -1
    end

    test "a failed repack is reported and leaves the poet as it was", %{user: user} do
      poet = TravelingPoet.Poets.get_poet_by_user(user.id)
      {:ok, poet} = TravelingPoet.Poets.update_poet(poet, %{status: "active"})

      assert {:error, :doctor_busy} =
               Provisioner.repack(user,
                 busy?: fn _ -> false end,
                 upgrade: fn _ -> {:error, :doctor_busy} end
               )

      assert TravelingPoet.Poets.get_poet_by_user(user.id).status == poet.status
    end
  end
end
