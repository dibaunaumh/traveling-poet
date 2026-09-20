defmodule TravelingPoetWeb.AiConsentController do
  @moduledoc """
  The iOS app's one-time consent to third-party AI.

  Everything a poet writes is made by AI models from outside providers, fed
  with what the reader tells it. Apple requires an app to say so plainly and
  get explicit agreement BEFORE any of that is sent (guideline 5.1.2(i)); a
  privacy policy alone does not count. Inside the app, every signed-in page
  leads here until the reader has agreed once
  (`UserAuth.on_mount(:ensure_authenticated)`); declining signs them out,
  since there is no part of the product that works without it.

  The website is unchanged: the step exists only in the app.
  """
  use TravelingPoetWeb, :controller

  alias TravelingPoet.Accounts
  alias TravelingPoetWeb.PageController

  def show(conn, _params) do
    user = conn.assigns.current_user

    if needed?(user, conn.assigns[:native_app]) do
      conn
      |> assign(:page_title, "Before your poet sets out")
      |> render(:show, layout: false)
    else
      redirect(conn, to: next_path(conn, user))
    end
  end

  def agree(conn, _params) do
    user = conn.assigns.current_user

    {:ok, user} =
      if user.ai_consent_at,
        do: {:ok, user},
        else: Accounts.update_user(user, %{ai_consent_at: DateTime.utc_now(:second)})

    redirect(conn, to: next_path(conn, user))
  end

  @doc "Whether this reader, in this client, still has to be asked."
  def needed?(%{ai_consent_at: nil}, true), do: true
  def needed?(_user, _native_app), do: false

  defp next_path(_conn, %{onboarding_completed: true}), do: ~p"/journal"
  defp next_path(conn, _user), do: PageController.onboarding_path(get_session(conn, :start_place))
end
