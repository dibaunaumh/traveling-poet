defmodule TravelingPoet.WebPush do
  @moduledoc """
  Browser push notifications for installed PWAs and desktop browsers.

  A user turns notifications on per device; the browser hands us a
  subscription (push-service endpoint + keys) and we keep it. When their poet
  publishes, `Notifier` calls `notify_entry/2`, which encrypts a small payload
  for each subscription and POSTs it to the push service. Dead subscriptions
  (404/410 — the user uninstalled the app or revoked permission) are pruned
  on the spot.

  Needs a VAPID key pair in config (`mix tpoet.gen_vapid_keys`); without one
  the whole feature reports itself as unconfigured and the UI stays hidden.
  """

  import Ecto.Query
  require Logger

  alias TravelingPoet.{Journal, Poets, Repo}
  alias TravelingPoet.WebPush.{Crypto, Subscription}

  # A daily entry is still worth a nudge a day later; after that it's stale.
  @ttl_seconds 24 * 3600

  def configured? do
    public_key() not in [nil, ""] and private_key() not in [nil, ""]
  end

  @doc "The VAPID public key the browser needs to subscribe (base64url)."
  def public_key, do: Application.get_env(:traveling_poet, :vapid_public_key)

  defp private_key, do: Application.get_env(:traveling_poet, :vapid_private_key)

  defp subject do
    Application.get_env(:traveling_poet, :vapid_subject) ||
      Application.get_env(:traveling_poet, :phoenix_url, "http://localhost:4000")
  end

  # -- subscriptions --

  @doc """
  Stores (or refreshes) the browser subscription `sub` — the JSON of
  `PushSubscription.toJSON()` — for `user`. Keyed by endpoint, so a page that
  re-reports its existing subscription on every load just touches the row,
  and a subscription that changes hands lands on the new user.
  """
  def subscribe(user, subscription, opts \\ [])

  def subscribe(
        user,
        %{"endpoint" => endpoint, "keys" => %{"p256dh" => p256dh, "auth" => auth}},
        opts
      ) do
    attrs = %{
      user_id: user.id,
      endpoint: endpoint,
      p256dh: p256dh,
      auth: auth,
      user_agent: opts |> Keyword.get(:user_agent) |> truncate(255)
    }

    # A silent re-report (page load) carries no user agent; keep the one we have.
    replace =
      if attrs.user_agent,
        do: [:user_id, :p256dh, :auth, :user_agent, :updated_at],
        else: [:user_id, :p256dh, :auth, :updated_at]

    %Subscription{}
    |> Subscription.changeset(attrs)
    |> Repo.insert(on_conflict: {:replace, replace}, conflict_target: :endpoint, returning: true)
  end

  def subscribe(_user, _malformed, _opts), do: {:error, :malformed_subscription}

  @doc "Forgets one device. Idempotent; scoped to the user so nobody can unsubscribe another."
  def unsubscribe(user, endpoint) when is_binary(endpoint) do
    from(s in Subscription, where: s.user_id == ^user.id and s.endpoint == ^endpoint)
    |> Repo.delete_all()

    :ok
  end

  def list_subscriptions(user) do
    from(s in Subscription, where: s.user_id == ^user.id, order_by: [asc: s.inserted_at])
    |> Repo.all()
  end

  def subscribed?(user, endpoint) when is_binary(endpoint) do
    Repo.exists?(
      from(s in Subscription, where: s.user_id == ^user.id and s.endpoint == ^endpoint)
    )
  end

  def subscribed?(_user, _), do: false

  def count(user) do
    Repo.aggregate(from(s in Subscription, where: s.user_id == ^user.id), :count)
  end

  # -- sending --

  @doc """
  Nudges every device of the poet's owner about a freshly published entry.
  Returns `{sent, pruned}` counts; safe to call when nobody subscribed.
  """
  def notify_entry(poet_id, entry_id) do
    with poet when not is_nil(poet) <- Poets.get_poet(poet_id),
         subs when subs != [] <- list_subscriptions(%{id: poet.user_id}) do
      entry = Journal.get_entry!(entry_id)
      payload = entry_payload(poet, entry, Journal.journey_day(entry))

      Enum.reduce(subs, {0, 0}, fn sub, {sent, pruned} ->
        case send_notification(sub, payload) do
          :ok -> {sent + 1, pruned}
          {:error, :gone} -> {sent, pruned + 1}
          {:error, _} -> {sent, pruned}
        end
      end)
    else
      _ -> {0, 0}
    end
  end

  @doc """
  What the device shows for a published entry, pure so it can be tested. The
  journey day and place make the title; the poet's own teaser (or title) is
  the body, so no two mornings read the same.
  """
  def entry_payload(poet, entry, day) do
    where = entry.place_name || poet.current_place_name

    %{
      title:
        if(where, do: "Day #{day} · #{poet.name} in #{where}", else: "Day #{day} · #{poet.name}"),
      body: present(entry.teaser) || present(entry.title) || "A new journal entry is waiting.",
      url: "/journal/#{entry.entry_date}",
      tag: "entry-#{entry.id}",
      icon: "/images/icon-192.png"
    }
  end

  defp present(nil), do: nil
  defp present(text), do: if(String.trim(text) == "", do: nil, else: text)

  @doc """
  Encrypts `payload` (a map, JSON-encoded) for one subscription and delivers
  it. `{:error, :gone}` means the push service disowned the subscription and
  it has been deleted.
  """
  def send_notification(%Subscription{} = sub, payload) when is_map(payload) do
    with true <- configured?() || {:error, :not_configured},
         {:ok, body} <- Crypto.encrypt(Jason.encode!(payload), sub.p256dh, sub.auth) do
      headers = [
        {"authorization",
         Crypto.vapid_authorization(sub.endpoint, subject(), public_key(), private_key())},
        {"content-encoding", "aes128gcm"},
        {"content-type", "application/octet-stream"},
        {"ttl", Integer.to_string(@ttl_seconds)},
        {"urgency", "normal"}
      ]

      request = [headers: headers, body: body, receive_timeout: 10_000] ++ req_options()

      case Req.post(sub.endpoint, request) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          mark(sub, last_sent_at: now(), last_error: nil)
          :ok

        {:ok, %Req.Response{status: status}} when status in [404, 410] ->
          Logger.info("web push: subscription #{sub.id} gone (#{status}); pruning")
          Repo.delete(sub)
          {:error, :gone}

        {:ok, %Req.Response{status: status, body: resp}} ->
          reason = "HTTP #{status}: #{inspect(resp) |> truncate(200)}"
          Logger.warning("web push: subscription #{sub.id} failed — #{reason}")
          mark(sub, last_error: reason)
          {:error, {:http, status}}

        {:error, reason} ->
          Logger.warning("web push: subscription #{sub.id} transport error — #{inspect(reason)}")
          mark(sub, last_error: inspect(reason) |> truncate(200))
          {:error, reason}
      end
    else
      {:error, :bad_subscription_keys} = err ->
        # Keys the browser handed us that no push service could have issued.
        Repo.delete(sub)
        err

      {:error, _} = err ->
        err
    end
  end

  def req_options, do: Application.get_env(:traveling_poet, :web_push_req_options, [])

  defp mark(sub, fields) do
    from(s in Subscription, where: s.id == ^sub.id) |> Repo.update_all(set: fields)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp truncate(nil, _), do: nil
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: binary_part(str, 0, max)
end
