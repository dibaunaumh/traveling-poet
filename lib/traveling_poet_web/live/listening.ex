defmodule TravelingPoetWeb.Listening do
  @moduledoc """
  The LiveView half of the page read aloud (card-122; on demand only,
  dec-004), shared by the owner's journal and the public journal. Each
  assigns the player's state from its entry, routes the hook's
  `narration_request` to `request/1`, and hands the three narration
  messages on the poet's topic (which both already subscribe to) to
  `handle_info/2`.

  A page shows the ring whenever the feature is configured: with the
  recording when it has one, with an estimate when it has not. The first
  press reads the page in a task (`Narration.Worker.request/1`) and the
  recording then stays for everyone. The daily cap per poet is the cost
  guard; a reading over it fails like any other, with a flash.
  """

  use Gettext, backend: TravelingPoetWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [clear_flash: 2, put_flash: 3]

  alias TravelingPoet.Narration

  # How long a page waits for its reading before putting the ring back. A
  # speech call takes about a sixth of the reading's length (a 4.5 minute
  # Hebrew page took 45 s on 2026-10-19, just past a flat 45 s wait), and
  # `Narration.request/2` gives it up to 180 s.
  @min_patience_ms 45_000
  @max_patience_ms 200_000

  def assign_narration(socket, entry, narration) do
    socket
    |> assign(:narration, narration)
    |> assign(:narration_on_demand, Narration.configured?())
    |> assign(:narration_pending, false)
    |> assign(:narration_late, false)
    |> assign(
      :narration_estimate,
      if(entry && is_nil(narration), do: Narration.estimated_seconds(entry))
    )
  end

  @doc "The hook pressed play on a page without a recording: read it."
  def request(socket) do
    %{entry: entry, narration: narration, narration_on_demand: on_demand} = socket.assigns

    if entry && is_nil(narration) && on_demand && !socket.assigns.narration_pending do
      Narration.Worker.request(entry.id)
      patience = patience_ms(socket.assigns.narration_estimate)
      Process.send_after(self(), {:narration_timeout, entry.id}, patience)
      {:noreply, socket |> assign(:narration_pending, true) |> assign(:narration_late, false)}
    else
      {:noreply, socket}
    end
  end

  @doc "How long to wait for a page whose reading is estimated at `seconds`."
  def patience_ms(nil), do: @min_patience_ms

  def patience_ms(seconds) when is_integer(seconds) do
    ((30 + div(seconds, 4)) * 1000)
    |> max(@min_patience_ms)
    |> min(@max_patience_ms)
  end

  # The reading never came back (a hung upload, a lost task): put the ring
  # back. If it does come after all, `:narration_ready` takes the notice away.
  def handle_info({:narration_timeout, entry_id}, socket) do
    %{entry: entry, narration: narration, narration_pending: pending} = socket.assigns

    if pending && entry && entry.id == entry_id && is_nil(narration) do
      {:noreply, socket} = handle_info({:narration_failed, entry_id}, socket)
      {:noreply, assign(socket, :narration_late, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:narration_failed, entry_id}, socket) do
    if shown?(socket, entry_id),
      do:
        {:noreply,
         socket
         |> assign(:narration_pending, false)
         |> put_flash(
           :error,
           dgettext("journal", "The page could not be read just now. Try again in a moment.")
         )},
      else: {:noreply, socket}
  end

  def handle_info({:narration_ready, entry_id}, socket) do
    if shown?(socket, entry_id) do
      socket =
        if socket.assigns[:narration_late], do: clear_flash(socket, :error), else: socket

      {:noreply,
       socket
       |> assign(:narration, Narration.narration_for(entry_id))
       |> assign(:narration_pending, false)
       |> assign(:narration_late, false)}
    else
      {:noreply, socket}
    end
  end

  defp shown?(socket, entry_id) do
    case socket.assigns.entry do
      %{id: ^entry_id} -> true
      _ -> false
    end
  end
end
