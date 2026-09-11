defmodule TravelingPoet.SpriteHoldTest do
  use ExUnit.Case, async: false

  alias TravelingPoet.SpriteHold

  setup do
    Application.put_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClientRecorder)
    Application.put_env(:traveling_poet, :sprites_client_listener, self())

    on_exit(fn ->
      Application.delete_env(:traveling_poet, :sprites_client)
      Application.delete_env(:traveling_poet, :sprites_client_listener)
    end)

    :ok
  end

  test "put sends a create-or-update PUT over the management socket" do
    assert :ok = SpriteHold.put("sprite-1", "tpoet-test-abc", "5m")

    assert_receive {:sprites_exec, "sprite-1", cmd}
    assert cmd =~ "--unix-socket /.sprite/api.sock"
    assert cmd =~ "-X PUT http://sprite/v1/tasks"
    assert cmd =~ ~s("name":"tpoet-test-abc")
    assert cmd =~ ~s("expire":"5m")
  end

  test "delete sends a DELETE for the named task" do
    assert :ok = SpriteHold.delete("sprite-1", "tpoet-test-abc")

    assert_receive {:sprites_exec, "sprite-1", cmd}
    assert cmd =~ "-X DELETE http://sprite/v1/tasks/tpoet-test-abc"
  end

  test "task_name is prefixed, purpose-tagged and unique" do
    a = SpriteHold.task_name("turn")
    b = SpriteHold.task_name("turn")

    assert a =~ ~r/^tpoet-turn-[0-9a-f]{6}$/
    assert a != b
  end

  test "with_hold creates the task before the work, refreshes it, and deletes it after" do
    result =
      SpriteHold.with_hold(
        "sprite-1",
        "turn",
        fn ->
          # The hold already exists when the work starts.
          assert_received {:sprites_exec, "sprite-1", first}
          assert first =~ "-X PUT"
          {:ok, task} = task_from_put(first)

          # A refresh lands while the work is still running.
          assert_receive {:sprites_exec, "sprite-1", refresh}, 500
          assert refresh =~ "-X PUT"
          assert refresh =~ task

          {:done, task}
        end,
        refresh_ms: 20,
        expire: "2m"
      )

    assert {:done, task} = result
    assert_receive {:sprites_exec, "sprite-1", delete}, 500
    assert delete =~ "-X DELETE http://sprite/v1/tasks/#{task}"
  end

  test "with_hold deletes the task when the work raises" do
    assert_raise RuntimeError, "boom", fn ->
      SpriteHold.with_hold("sprite-1", "turn", fn -> raise "boom" end, refresh_ms: 60_000)
    end

    assert_receive {:sprites_exec, "sprite-1", put}
    {:ok, task} = task_from_put(put)
    assert_receive {:sprites_exec, "sprite-1", delete}, 500
    assert delete =~ "-X DELETE http://sprite/v1/tasks/#{task}"
  end

  test "with_hold stops refreshing once the work is done" do
    SpriteHold.with_hold("sprite-1", "turn", fn -> :ok end, refresh_ms: 20)

    assert_receive {:sprites_exec, "sprite-1", _put}
    assert_receive {:sprites_exec, "sprite-1", _delete}, 500
    refute_receive {:sprites_exec, "sprite-1", _}, 100
  end

  test "with_hold on a nil sprite runs the work with no execs" do
    assert :ran = SpriteHold.with_hold(nil, "turn", fn -> :ran end)
    refute_receive {:sprites_exec, _, _}
  end

  defp task_from_put(cmd) do
    case Regex.run(~r/"name":"([^"]+)"/, cmd) do
      [_, task] -> {:ok, task}
      _ -> :error
    end
  end
end
