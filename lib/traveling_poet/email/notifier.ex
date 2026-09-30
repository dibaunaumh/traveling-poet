defmodule TravelingPoet.Email.Notifier do
  @moduledoc """
  Emails the owner when their poet publishes a page. Sibling of
  `WebPush.Notifier` and `Telegram.Notifier` on "journal:published" (sent
  once per entry: a revision does not broadcast there). No-op unless
  `Email.configured?/0`.

  Skipped: readers who turned it off (`users.email_notify`), and Apple
  "Hide My Email" relay addresses, which only accept mail from a sender
  registered with Apple.
  """

  use GenServer
  require Logger

  alias TravelingPoet.{Accounts, Email, Journal, Poets}
  alias TravelingPoet.Email.EntryEmail

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Email.configured?() and Application.get_env(:traveling_poet, :email_notifier, true) do
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "journal:published")
      {:ok, %{}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info({:journal_published, poet_id, entry_id}, state) do
    Task.start(fn -> send_entry(poet_id, entry_id) end)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Builds and sends the page email for one entry, when the reader wants it."
  def send_entry(poet_id, entry_id) do
    with %{} = poet <- Poets.get_poet(poet_id),
         %{} = user <- Accounts.get_user(poet.user_id),
         true <- wants_email?(user) do
      entry = Journal.get_entry!(entry_id)

      message =
        EntryEmail.build(%{
          user: user,
          poet: poet,
          entry: entry,
          day: Journal.journey_day(entry),
          drawing_url: drawing_url(entry),
          page_url: url("/journal/#{Date.to_iso8601(entry.entry_date)}"),
          unsubscribe_url: url("/email/unsubscribe/#{unsubscribe_token(user)}")
        })

      case Email.deliver(message) do
        {:ok, _id} -> Logger.info("email: entry #{entry_id} sent to user #{user.id}")
        other -> other
      end
    else
      _ -> :skipped
    end
  end

  @doc false
  def wants_email?(%{email_notify: true, email: email}) when is_binary(email),
    do: not String.ends_with?(String.downcase(email), "@privaterelay.appleid.com")

  def wants_email?(_user), do: false

  @unsub_salt "email-unsubscribe"
  @media_salt "email-media"

  @doc "A token for the one-click unsubscribe link; never expires."
  def unsubscribe_token(user),
    do: Phoenix.Token.sign(TravelingPoetWeb.Endpoint, @unsub_salt, user.id)

  def verify_unsubscribe(token),
    do: Phoenix.Token.verify(TravelingPoetWeb.Endpoint, @unsub_salt, token, max_age: :infinity)

  @doc "A signature that lets an email show one drawing of a private journal."
  def media_sig(media_id),
    do: Phoenix.Token.sign(TravelingPoetWeb.Endpoint, @media_salt, media_id)

  def verify_media_sig(sig, media_id) do
    match?(
      {:ok, ^media_id},
      Phoenix.Token.verify(TravelingPoetWeb.Endpoint, @media_salt, sig, max_age: 60 * 86_400)
    )
  end

  defp drawing_url(entry) do
    case Journal.entry_illustration(entry) do
      %{id: id} -> url("/media/#{id}?sig=#{media_sig(id)}")
      _ -> nil
    end
  end

  defp url(path), do: TravelingPoetWeb.Endpoint.url() <> path
end
