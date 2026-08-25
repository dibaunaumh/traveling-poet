defmodule TravelingPoet.Telegram.Pairing do
  @moduledoc """
  Pairing between an app user and their Telegram DM with the central bot:
  the app mints a short-lived random token stored on the user, renders a
  `https://t.me/<bot>?start=<token>` deep link, and the poller matches the
  `/start <token>` message to store the chat_id.
  """

  alias TravelingPoet.Accounts
  alias TravelingPoet.Telegram.Client

  @token_ttl_minutes 15

  def mint_pair_link(user) do
    with username when is_binary(username) <- Client.bot_username() || {:error, :no_bot_username} do
      token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

      expires =
        DateTime.add(DateTime.utc_now(), @token_ttl_minutes * 60) |> DateTime.truncate(:second)

      case Accounts.update_user(user, %{
             telegram_pair_token: token,
             telegram_pair_token_expires_at: expires
           }) do
        {:ok, _} -> {:ok, "https://t.me/#{username}?start=#{token}"}
        {:error, _} = err -> err
      end
    end
  end

  @doc "Called by the poller on `/start <token>`. Returns {:ok, user} on success."
  def complete_pairing(token, chat_id, telegram_username) do
    with user when not is_nil(user) <- Accounts.get_user_by_telegram_pair_token(token),
         true <- token_valid?(user) do
      result =
        Accounts.update_user(user, %{
          telegram_chat_id: chat_id,
          telegram_username: telegram_username,
          telegram_paired_at: DateTime.utc_now() |> DateTime.truncate(:second),
          telegram_pair_token: nil,
          telegram_pair_token_expires_at: nil
        })

      with {:ok, updated} <- result do
        Phoenix.PubSub.broadcast(
          TravelingPoet.PubSub,
          "user:#{updated.id}",
          {:telegram_paired, telegram_username}
        )

        {:ok, updated}
      end
    else
      _ -> {:error, :invalid_token}
    end
  end

  def unpair(user) do
    Accounts.update_user(user, %{
      telegram_chat_id: nil,
      telegram_username: nil,
      telegram_paired_at: nil
    })
  end

  defp token_valid?(%{telegram_pair_token_expires_at: nil}), do: false

  defp token_valid?(%{telegram_pair_token_expires_at: expires}) do
    DateTime.compare(DateTime.utc_now(), expires) == :lt
  end
end
