defmodule TravelingPoet.Messaging do
  @moduledoc """
  Chat channels a poet can reach its owner on. One central bot/number per
  provider; a `Messaging.Channel` row pairs a user with their conversation.

  Pairing is the same dance everywhere: the app mints a short-lived token,
  renders a provider deep link carrying it, and the inbound message with that
  token tells us which conversation belongs to which user.
  """

  import Ecto.Query

  alias TravelingPoet.Messaging.{Channel, Notification}
  alias TravelingPoet.Repo

  require Logger

  @adapters %{
    "telegram" => TravelingPoet.Telegram.Client,
    "whatsapp" => TravelingPoet.WhatsApp.Client
  }

  @token_ttl_minutes 15

  def providers, do: Channel.providers()

  def adapter(provider), do: Map.fetch!(@adapters, provider)

  def configured?(provider), do: adapter(provider).configured?()

  def configured_providers, do: Enum.filter(providers(), &configured?/1)

  def label(provider), do: adapter(provider).label()

  ## Lookup

  def get_channel(user_id, provider) do
    Repo.get_by(Channel, user_id: user_id, provider: provider)
  end

  def list_channels(user_id) do
    Repo.all(from c in Channel, where: c.user_id == ^user_id)
  end

  @doc "Channels that have completed pairing, i.e. we can actually send to them."
  def paired_channels(user_id) do
    Repo.all(
      from c in Channel,
        where: c.user_id == ^user_id and not is_nil(c.external_id)
    )
  end

  def paired?(user, provider) do
    case get_channel(user.id, provider) do
      nil -> false
      channel -> Channel.paired?(channel)
    end
  end

  def any_paired?(user), do: paired_channels(user.id) != []

  def get_channel_by_external_id(provider, external_id) when is_binary(external_id) do
    Repo.get_by(Channel, provider: provider, external_id: external_id)
  end

  def get_channel_by_external_id(_, _), do: nil

  ## Pairing

  @doc """
  Mints a fresh pairing token for `provider` and returns the deep link the
  user should open. Re-minting replaces any outstanding token.
  """
  def mint_pair_link(user, provider) do
    token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    expires =
      DateTime.add(DateTime.utc_now(), @token_ttl_minutes * 60) |> DateTime.truncate(:second)

    with {:ok, _channel} <-
           upsert_channel(user.id, provider, %{
             pair_token: token,
             pair_token_expires_at: expires
           }) do
      adapter(provider).pair_link(token)
    end
  end

  @doc """
  Called from an inbound `PAIR <token>` / `/start <token>` message. Returns
  `{:ok, user, channel}` once the conversation is bound to the user.
  """
  def complete_pairing(provider, token, external_id, username) do
    external_id = to_string(external_id)

    with channel when not is_nil(channel) <- get_channel_by_pair_token(provider, token),
         true <- token_valid?(channel),
         :ok <- release_external_id(provider, external_id, channel.id),
         {:ok, channel} <-
           update_channel(channel, %{
             external_id: external_id,
             username: username,
             paired_at: now(),
             last_inbound_at: now(),
             pair_token: nil,
             pair_token_expires_at: nil
           }) do
      user = TravelingPoet.Accounts.get_user(channel.user_id)

      Phoenix.PubSub.broadcast(
        TravelingPoet.PubSub,
        "user:#{channel.user_id}",
        {:messaging_paired, provider, username}
      )

      {:ok, user, channel}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def unpair(user, provider) do
    case get_channel(user.id, provider) do
      nil ->
        {:ok, nil}

      channel ->
        update_channel(channel, %{
          external_id: nil,
          username: nil,
          paired_at: nil,
          last_inbound_at: nil
        })
    end
  end

  def touch_inbound(%Channel{} = channel) do
    update_channel(channel, %{last_inbound_at: now()})
  end

  ## Sending

  @doc "Free-form message on an established channel (a reply to the user)."
  def send_message(%Channel{} = channel, text, opts \\ []) do
    send_raw(channel.provider, channel.external_id, text, opts)
  end

  @doc """
  Free-form message to a conversation we may not have a channel row for —
  the \"this chat isn't paired yet\" replies.
  """
  def send_raw(provider, external_id, text, opts \\ []) do
    adapter(provider).send_message(to_string(external_id), text, opts)
  end

  @doc """
  Sends a proactive notification on every channel the user has paired.
  Returns the number of channels reached.
  """
  def notify(user, %Notification{} = notification) do
    user.id
    |> paired_channels()
    |> Enum.count(fn channel ->
      case adapter(channel.provider).send_notification(channel.external_id, notification) do
        :ok ->
          true

        {:error, reason} ->
          Logger.warning(
            "Messaging: #{channel.provider} notification to user #{user.id} failed: #{inspect(reason)}"
          )

          false
      end
    end)
  end

  ## Internals

  defp get_channel_by_pair_token(provider, token) when is_binary(token) and token != "" do
    Repo.get_by(Channel, provider: provider, pair_token: token)
  end

  defp get_channel_by_pair_token(_, _), do: nil

  # A conversation can only belong to one user: if this chat was previously
  # paired to somebody else (or to this user's stale row), clear that first.
  defp release_external_id(provider, external_id, keep_id) do
    case get_channel_by_external_id(provider, external_id) do
      nil ->
        :ok

      %Channel{id: ^keep_id} ->
        :ok

      other ->
        case update_channel(other, %{external_id: nil, paired_at: nil}) do
          {:ok, _} -> :ok
          err -> err
        end
    end
  end

  defp upsert_channel(user_id, provider, attrs) do
    case get_channel(user_id, provider) do
      nil ->
        %Channel{}
        |> Channel.changeset(Map.merge(attrs, %{user_id: user_id, provider: provider}))
        |> Repo.insert()

      channel ->
        update_channel(channel, attrs)
    end
  end

  defp update_channel(channel, attrs) do
    channel |> Channel.changeset(attrs) |> Repo.update()
  end

  defp token_valid?(%Channel{pair_token_expires_at: nil}), do: false

  defp token_valid?(%Channel{pair_token_expires_at: expires}) do
    DateTime.compare(DateTime.utc_now(), expires) == :lt
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
