defmodule TravelingPoetWeb.Bookmarking do
  @moduledoc """
  The LiveView half of bookmarks (`TravelingPoet.Bookmarks`), shared by the
  owner's guide, public guides and Discover. Each assigns `@bookmarks` (the
  reader's saved keys, nil when signed out, which hides every Save button)
  and routes `toggle_bookmark` here.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias TravelingPoet.Bookmarks

  def assign_bookmarks(socket) do
    case socket.assigns[:current_user] do
      %{id: id} -> assign(socket, :bookmarks, Bookmarks.keys(id))
      _ -> assign(socket, :bookmarks, nil)
    end
  end

  @doc """
  `toggle_bookmark` with a kind and the item's id. A negative id is a saved
  copy whose item left its page (see `Bookmarks.list/1`): removing it is
  the only thing to do.
  """
  def handle_event("toggle_bookmark", %{"kind" => kind, "id" => id}, socket) do
    case socket.assigns[:current_user] do
      %{id: user_id} ->
        result =
          case Integer.parse(to_string(id)) do
            {n, ""} when n < 0 -> Bookmarks.remove(user_id, -n)
            _ -> Bookmarks.toggle(user_id, kind, id)
          end

        socket =
          case result do
            {:ok, _} -> socket
            _ -> put_flash(socket, :error, "That could not be saved.")
          end

        {:noreply, assign_bookmarks(socket)}

      _ ->
        {:noreply, socket}
    end
  end
end
