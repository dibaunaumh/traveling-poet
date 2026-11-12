defmodule TravelingPoetWeb.LocalQuestionLive do
  @moduledoc """
  The short form a local answers a visiting poet's question in (card-10,
  dec-020): reached from the push, Telegram or email notice, never through
  the local's own poet. Only the reader the question was put to can open
  it; anyone else is sent to their journal.
  """

  use TravelingPoetWeb, :live_view

  alias TravelingPoet.LocalVoices

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case LocalVoices.get_for_user(user.id, id) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/journal")}

      question ->
        {:ok,
         socket
         |> assign(
           question: question,
           page_title: LocalVoices.notice(question).title,
           credit: LocalVoices.credit_text(LocalVoices.credit(user, question)),
           form: to_form(%{"answer" => question.answer || ""}, as: :local)
         )}
    end
  end

  @impl true
  def handle_event("validate", %{"local" => params}, socket),
    do: {:noreply, assign(socket, :form, to_form(params, as: :local))}

  def handle_event("send", %{"local" => %{"answer" => text} = params}, socket) do
    case LocalVoices.answer(socket.assigns.question, text) do
      {:ok, question} ->
        {:noreply,
         assign(socket, :question, Map.put(question, :poet, socket.assigns.question.poet))}

      {:error, :closed} ->
        {:noreply, put_flash(socket, :error, dgettext("locals", "This question has closed."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params, as: :local))
         |> put_flash(:error, dgettext("locals", "A few words, up to 1500 characters."))}
    end
  end

  def handle_event("decline", _params, socket) do
    {:ok, question} = LocalVoices.decline(socket.assigns.question)
    {:noreply, assign(socket, :question, Map.put(question, :poet, socket.assigns.question.poet))}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:notice, LocalVoices.notice(assigns.question))
      |> assign(:open?, LocalVoices.open?(assigns.question))

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div id="local-question" class="max-w-xl mx-auto space-y-4">
        <h1 class="text-2xl font-semibold">{@notice.title}</h1>
        <p>
          <.link navigate={~p"/p/#{@question.poet.slug}"} class="link">
            {dgettext("locals", "Read %{poet}'s journal", poet: @question.poet.name)}
          </.link>
        </p>

        <div :if={@question.status == "answered"} id="local-answered" class="space-y-2">
          <p>
            {dgettext("locals", "Thank you. %{poet} will have your tips with the next page.",
              poet: @question.poet.name
            )}
          </p>
          <blockquote class="border-s-2 border-base-300 ps-3 whitespace-pre-line opacity-80">
            {@question.answer}
          </blockquote>
        </div>

        <p :if={@question.status == "declined"} id="local-declined">
          {dgettext("locals", "No tips this time. Thank you for letting us know.")}
        </p>

        <p :if={@question.status == "open" and not @open?} id="local-closed">
          {dgettext("locals", "This question has closed: %{poet} has moved on.",
            poet: @question.poet.name
          )}
        </p>

        <div :if={@question.status == "open" and @open?} class="space-y-3">
          <p>{@notice.body}</p>
          <.form
            for={@form}
            id="local-answer"
            phx-change="validate"
            phx-submit="send"
            class="space-y-3"
          >
            <.input
              field={@form[:answer]}
              type="textarea"
              rows="6"
              maxlength="1500"
              placeholder={dgettext("locals", "A place, a dish, a walk, and why")}
            />
            <p class="text-sm opacity-70">
              {dgettext(
                "locals",
                "%{poet} will translate it if needed and check the places you name. Under it on the page: \"%{credit}\".",
                poet: @question.poet.name,
                credit: @credit
              )}
              <.link navigate={~p"/settings#home"} class="link">
                {dgettext("locals", "Change how you are named")}
              </.link>
            </p>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm">
                {dgettext("locals", "Send")}
              </button>
              <button
                type="button"
                id="local-decline"
                phx-click="decline"
                class="btn btn-ghost btn-sm"
              >
                {dgettext("locals", "Not this time")}
              </button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
