defmodule TravelingPoet.Messaging.Adapter do
  @moduledoc """
  What a chat provider has to implement to carry a poet's conversation.
  Implemented by `TravelingPoet.Telegram.Client` and
  `TravelingPoet.WhatsApp.Client`.
  """

  alias TravelingPoet.Messaging.Notification

  @doc "True when this server has credentials for the provider."
  @callback configured?() :: boolean()

  @doc "Human name, for UI copy."
  @callback label() :: String.t()

  @doc """
  Deep link that opens the provider's app with the pairing message ready to
  send. The user still has to hit send/start — that inbound message is what
  reaches us with the token.
  """
  @callback pair_link(token :: String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "Free-form reply. Only valid in response to the user (see Notification)."
  @callback send_message(external_id :: String.t(), text :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "Proactive message, sent whether or not the user wrote to us recently."
  @callback send_notification(external_id :: String.t(), notification :: Notification.t()) ::
              :ok | {:error, term()}
end
