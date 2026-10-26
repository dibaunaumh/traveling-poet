defmodule TravelingPoetWeb.FeedbackLive do
  @moduledoc """
  `/feedback` (card-137): tell us something is broken, something you would
  change, or something missing. Open to everyone (card-63): a signed-in
  reader is known, a visitor leaves an email address. `?from=` is the page
  the reader came from, kept with the message so a bug report says where.

  The message itself goes through `Feedback.create_message/2`, which pages
  the admins on Telegram.
  """

  use TravelingPoetWeb, :live_view

  alias TravelingPoet.Feedback
  alias TravelingPoet.Feedback.Message

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, dgettext("feedback", "Send feedback"))
     |> assign(:from, from_path(params["from"]))
     |> assign(:sent, false)
     |> assign(:error, nil)
     |> assign_form(Feedback.change_message(%{"kind" => kind(params["kind"])}))}
  end

  # Only a path on this site, never somewhere else to send the reader back to
  defp from_path("/" <> rest = path) when byte_size(path) <= 255 do
    if String.starts_with?(rest, ["/", "\\"]), do: nil, else: path
  end

  defp from_path(_), do: nil

  defp kind(kind) when kind in ["broken", "change", "missing", "other"], do: kind
  defp kind(_), do: "broken"

  defp assign_form(socket, changeset),
    do: assign(socket, :form, to_form(changeset, as: :feedback))

  @impl true
  def handle_event("validate", %{"feedback" => params}, socket) do
    changeset =
      params
      |> Map.take(["kind", "body", "email"])
      |> Feedback.change_message()
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  # The hidden field only a script fills in: thank it and keep nothing
  def handle_event("send", %{"feedback" => %{"website" => trap}}, socket) when trap != "" do
    {:noreply, assign(socket, :sent, true)}
  end

  def handle_event("send", %{"feedback" => params}, socket) do
    attrs =
      params
      |> Map.take(["kind", "body", "email"])
      |> Map.put("page", socket.assigns.from)
      |> Map.put("client", if(socket.assigns[:native_app], do: "iOS app", else: "web"))

    case Feedback.create_message(socket.assigns.current_user, attrs) do
      {:ok, _message} ->
        {:noreply, assign(socket, sent: true, error: nil)}

      {:error, :too_many} ->
        {:noreply,
         assign(
           socket,
           :error,
           dgettext("feedback", "That is a lot of notes for one day. Please try again tomorrow.")
         )}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp kinds do
    [
      {"broken", dgettext("feedback", "Something is broken")},
      {"change", dgettext("feedback", "I would change something")},
      {"missing", dgettext("feedback", "Something is missing")},
      {"other", dgettext("feedback", "Something else")}
    ]
  end

  defp placeholder("broken"),
    do: dgettext("feedback", "What happened, and what did you expect to happen?")

  defp placeholder("change"), do: dgettext("feedback", "What would you change, and why?")

  defp placeholder("missing"),
    do: dgettext("feedback", "What would you like Traveling Poet to do?")

  defp placeholder(_), do: dgettext("feedback", "Tell us anything.")

  defp back_path(%{from: from}) when is_binary(from), do: from
  defp back_path(%{current_user: %{}}), do: ~p"/journal"
  defp back_path(_), do: ~p"/"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} credits_low={assigns[:credits_low]}>
      <div class="mx-auto max-w-xl py-6">
        <h1 class="text-2xl font-semibold mb-1">{dgettext("feedback", "Send feedback")}</h1>

        <div :if={@sent} id="feedback-sent" class="space-y-4">
          <p class="opacity-80">
            {dgettext(
              "feedback",
              "Thank you. Every note is read, and it shapes what we build next."
            )}
          </p>
          <.link navigate={back_path(assigns)} class="btn btn-sm btn-primary">
            {dgettext("feedback", "Back")}
          </.link>
        </div>

        <div :if={!@sent}>
          <p class="opacity-70 mb-5">
            {dgettext(
              "feedback",
              "Something not working, something you would change, or something you miss? Tell us here."
            )}
          </p>

          <.form
            for={@form}
            id="feedback-form"
            phx-change="validate"
            phx-submit="send"
            class="space-y-4"
          >
            <fieldset>
              <legend class="text-sm font-medium mb-2">
                {dgettext("feedback", "What is it about?")}
              </legend>
              <div class="flex flex-wrap gap-2">
                <label
                  :for={{value, label} <- kinds()}
                  class={[
                    "btn btn-sm",
                    if(@form[:kind].value == value,
                      do: "btn-primary",
                      else: "btn-ghost border-base-300"
                    )
                  ]}
                >
                  <input
                    type="radio"
                    name={@form[:kind].name}
                    value={value}
                    checked={@form[:kind].value == value}
                    class="sr-only"
                  />
                  {label}
                </label>
              </div>
            </fieldset>

            <.input
              field={@form[:body]}
              type="textarea"
              label={dgettext("feedback", "Your note")}
              placeholder={placeholder(@form[:kind].value)}
              rows="6"
              maxlength={Message.body_max()}
              required
            />

            <.input
              :if={is_nil(@current_user)}
              field={@form[:email]}
              type="email"
              label={dgettext("feedback", "Your email, so we can write back")}
              autocomplete="email"
              required
            />

            <%!-- For scripts only: people never see it --%>
            <div class="hidden" aria-hidden="true">
              <input type="text" name="feedback[website]" value="" tabindex="-1" autocomplete="off" />
            </div>

            <p :if={@error} class="text-error text-sm" id="feedback-error">{@error}</p>

            <div class="flex items-center gap-3">
              <button
                type="submit"
                class="btn btn-primary"
                phx-disable-with={dgettext("feedback", "Sending...")}
              >
                {dgettext("feedback", "Send")}
              </button>
              <.link navigate={back_path(assigns)} class="btn btn-ghost btn-sm">
                {dgettext("feedback", "Cancel")}
              </.link>
            </div>
          </.form>

          <p class="text-xs opacity-60 mt-6">
            <.rich text={
              dgettext("feedback", "You can also write to %{address}.", address: marker(:address))
            }>
              <:part name="address">
                <a href="mailto:support@poet.travel" class="link">support@poet.travel</a>
              </:part>
            </.rich>
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
