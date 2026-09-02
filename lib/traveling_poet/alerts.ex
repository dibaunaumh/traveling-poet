defmodule TravelingPoet.Alerts do
  @moduledoc """
  Operator alerts over Telegram. One place to answer "who gets paged?":
  `:alert_telegram_chat_id` (env ALERT_TELEGRAM_CHAT_ID) when set, otherwise
  every admin who has paired Telegram.

  Extracted from `FleetHealth.Alerter` when the change stream needed the same
  delivery. Callers own composition and dedup; this only sends.
  """

  import Ecto.Query

  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Repo
  alias TravelingPoet.Telegram.Client

  @doc "Sends `text` to every recipient; halts on the first delivery error."
  def notify_admins(text) when is_binary(text) do
    case recipients() do
      [] ->
        {:error, :no_recipients}

      chat_ids ->
        Enum.reduce_while(chat_ids, :ok, fn chat_id, _acc ->
          case Client.send_message(chat_id, text, disable_web_page_preview: true) do
            :ok -> {:cont, :ok}
            err -> {:halt, err}
          end
        end)
    end
  end

  @doc "Absolute admin URL for a path like `/admin`, from `:phoenix_url`."
  def admin_url(path \\ "/admin") do
    base = Application.get_env(:traveling_poet, :phoenix_url, "https://poet.travel")
    String.trim_trailing(base, "/") <> path
  end

  defp recipients do
    case Application.get_env(:traveling_poet, :alert_telegram_chat_id) do
      nil -> admin_chat_ids()
      "" -> admin_chat_ids()
      chat_id -> [chat_id]
    end
  end

  defp admin_chat_ids do
    User
    |> where([u], u.is_admin == true and not is_nil(u.telegram_chat_id))
    |> select([u], u.telegram_chat_id)
    |> Repo.all()
  end
end
