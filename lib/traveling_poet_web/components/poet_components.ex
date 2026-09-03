defmodule TravelingPoetWeb.PoetComponents do
  @moduledoc """
  Chip pickers shared by onboarding and Settings, so a book or an interest
  chosen at signup looks and behaves the same when edited later.

  Every chip is `type="button"` so it can sit inside a `phx-submit` form
  without submitting it, and carries an id so tests can target it.
  """
  use TravelingPoetWeb, :html

  attr :books, :list, required: true, doc: "the curated reading list"
  attr :selected, :any, required: true, doc: "MapSet of selected indices"
  attr :event, :string, default: "toggle_reading"

  def book_chips(assigns) do
    ~H"""
    <div id="book-chips" class="flex flex-wrap gap-2">
      <button
        :for={{book, idx} <- Enum.with_index(@books)}
        type="button"
        id={"book-chip-#{idx}"}
        phx-click={@event}
        phx-value-idx={idx}
        class={[
          "btn btn-xs",
          if(MapSet.member?(@selected, idx), do: "btn-primary", else: "btn-outline")
        ]}
      >
        {book["title"]}
      </button>
    </div>
    """
  end

  attr :interests, :list, required: true
  attr :selected, :any, required: true, doc: "MapSet of selected labels"
  attr :event, :string, default: "toggle_interest"

  def interest_chips(assigns) do
    ~H"""
    <div id="interest-chips" class="flex flex-wrap gap-2">
      <button
        :for={{label, idx} <- Enum.with_index(@interests)}
        type="button"
        id={"interest-chip-#{idx}"}
        phx-click={@event}
        phx-value-label={label}
        class={[
          "btn btn-xs",
          if(MapSet.member?(@selected, label), do: "btn-primary", else: "btn-outline")
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  attr :personalities, :list, required: true, doc: "list of %{label, text}"
  attr :selected_idx, :any, required: true, doc: "index of the active preset, or nil for custom"
  attr :custom, :boolean, default: false

  def personality_chips(assigns) do
    ~H"""
    <div id="personality-chips" class="flex flex-wrap gap-2">
      <button
        :for={{preset, idx} <- Enum.with_index(@personalities)}
        type="button"
        id={"personality-chip-#{idx}"}
        phx-click="pick_personality"
        phx-value-idx={idx}
        class={[
          "btn btn-xs",
          if(!@custom and @selected_idx == idx, do: "btn-primary", else: "btn-outline")
        ]}
      >
        {preset["label"]}
      </button>
      <button
        type="button"
        id="personality-chip-custom"
        phx-click="custom_personality"
        class={["btn btn-xs", if(@custom, do: "btn-primary", else: "btn-outline")]}
      >
        ✍️ Write your own
      </button>
    </div>
    """
  end
end
