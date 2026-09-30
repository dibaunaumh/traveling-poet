defmodule TravelingPoet.Email do
  @moduledoc """
  Sends email through Resend's HTTP API (https://resend.com/docs/api-reference).
  Req only, like every other outbound call; off unless `RESEND_API_KEY` is
  set (nil in test, where requests go to a `Req.Test` stub).

  The one email today is the daily page (`Email.EntryEmail`, sent by
  `Email.Notifier`): 9 of the 11 readers who signed up in September had no
  notification channel at all and stopped coming back within days.
  """

  require Logger

  @api_url "https://api.resend.com/emails"

  def configured?, do: key() not in [nil, ""]

  def from,
    do: Application.get_env(:traveling_poet, :email_from, "Traveling Poet <journal@poet.travel>")

  @doc """
  "Nam via Traveling Poet" at the configured address: mail from a named
  person, not a brand, is what Gmail keeps out of Promotions. The name is
  quoted, and anything that could break the header is dropped.
  """
  def from_poet(name) when is_binary(name) do
    address =
      case Regex.run(~r/<([^>]+)>/, from()) do
        [_, address] -> address
        _ -> from()
      end

    clean = name |> String.replace(~r/["\\<>\r\n]/, "") |> String.trim()
    if clean == "", do: from(), else: ~s("#{clean} via Traveling Poet" <#{address}>)
  end

  def from_poet(_), do: from()

  @doc """
  Sends one message: `%{to, subject, html, text}` and optional `from` and
  `headers`.
  Returns `{:ok, id}` or `{:error, reason}`.
  """
  def deliver(%{to: to, subject: subject, html: html, text: text} = message, opts \\ []) do
    key = Keyword.get(opts, :api_key, key())

    body = %{
      from: Map.get(message, :from, from()),
      to: [to],
      subject: subject,
      html: html,
      text: text,
      headers: Map.get(message, :headers, %{})
    }

    options =
      [json: body, headers: [{"authorization", "Bearer #{key}"}], retry: false] ++
        Application.get_env(:traveling_poet, :email_req_options, [])

    case Req.post(@api_url, options) do
      {:ok, %{status: status, body: %{"id" => id}}} when status in 200..299 ->
        {:ok, id}

      {:ok, %{status: status, body: resp}} ->
        Logger.warning("Email: Resend returned #{status}: #{inspect(resp, limit: 200)}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.warning("Email: request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp key, do: Application.get_env(:traveling_poet, :resend_api_key)
end
