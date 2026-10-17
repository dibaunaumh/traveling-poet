defmodule TravelingPoet.TurnErrorsSink do
  @moduledoc """
  The test env's turn-error reporter: hands the socket's report to the
  process registered as `:turn_errors_sink`, so a socket test can assert
  the hook fired without a database or a Telegram call behind it.
  """

  def report_async(user_id, message) do
    if pid = Process.whereis(:turn_errors_sink), do: send(pid, {:turn_error, user_id, message})
    {:ok, self()}
  end
end
