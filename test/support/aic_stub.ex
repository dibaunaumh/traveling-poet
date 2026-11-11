defmodule TravelingPoet.AiCStub do
  @moduledoc """
  Alice-in-Context for a test: the client is pointed at a stub that hands
  every batch to the test process, and `sent/0` returns what the app emitted.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias AliceInContext.Outbox
  alias TravelingPoet.AiC.ReadTally

  @doc "Call from `setup`. Events left over from an earlier test are thrown away."
  def start do
    Application.put_env(:alice_in_context, :endpoint, "http://aic.test")
    Application.put_env(:alice_in_context, :token, "tok")
    Application.put_env(:alice_in_context, :source, "traveling-poet")
    test_pid = self()

    Req.Test.stub(AliceInContext, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:aic_batch, Jason.decode!(body)})
      Req.Test.json(%Plug.Conn{conn | status: 202}, %{status: "accepted"})
    end)

    Req.Test.allow(AliceInContext, self(), Process.whereis(Outbox))

    on_exit(fn ->
      # Nothing this test emitted and never looked at may reach the next test's
      # stub, or sit in the outbox once there is no endpoint to post it to.
      # The test process and its stub are gone by now, so this one swallows.
      Req.Test.stub(AliceInContext, fn conn ->
        Req.Test.json(%Plug.Conn{conn | status: 202}, %{status: "accepted"})
      end)

      Req.Test.allow(AliceInContext, self(), Process.whereis(Outbox))
      ReadTally.flush()
      Outbox.flush()

      Application.delete_env(:alice_in_context, :endpoint)
      Application.delete_env(:alice_in_context, :token)
    end)

    sent()
    :ok
  end

  @doc """
  Every event emitted since the last call, oldest first; with a verb, only
  those (usage metrics, which share verbs with what they count, left out).
  The read tally hands over its own first. The PubSub tap subscribes at boot
  only when AiC is configured, so in a test it forwards nothing.
  """
  def sent(verb \\ nil) do
    ReadTally.flush()
    Outbox.flush()
    events = drain([])

    if verb,
      do: Enum.filter(events, &(&1["verb"] == verb and &1["type"] != "metric")),
      else: events
  end

  defp drain(acc) do
    receive do
      {:aic_batch, %{"events" => events}} -> drain(acc ++ events)
    after
      0 -> acc
    end
  end
end
