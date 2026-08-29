defmodule TravelingPoet.Messaging.Notification do
  @moduledoc """
  A proactive message the app sends *to* a user — the daily "entry published"
  note and the credits warnings.

  Providers differ in what they'll accept unprompted: Telegram takes any text,
  WhatsApp only takes a pre-approved template once the 24h customer-service
  window has closed. So a notification carries both — `:text` for providers
  that take free-form, and `:key` + `:params` for those that need a template.
  Keep the two in sync: `text` should read like the registered template body
  with its variables filled in.

  See `TravelingPoet.WhatsApp.Client` for the template bodies to register in
  the Meta dashboard.
  """

  @enforce_keys [:key, :params, :text]
  defstruct [:key, :params, :text, preview_url: false]

  @type key :: :journal_published | :credits_low | :credits_empty

  @type t :: %__MODULE__{
          key: key(),
          params: [String.t()],
          text: String.t(),
          preview_url: boolean()
        }
end
