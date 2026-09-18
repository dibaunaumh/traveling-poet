defmodule TravelingPoet.GoogleCalendar do
  @moduledoc """
  The companion's Google Calendar, read to find upcoming trips.

  The grant is `calendar.events.readonly` on the account's shared Google
  grant (`TravelingPoet.GoogleAuth`); only the primary calendar is read, and
  nothing is ever written. Events come back normalised to the few fields
  trip detection needs (`normalize_event/1`); the title is carried only as
  far as the sync and never stored.

  Every request goes through `GoogleAuth.req_options/0`, stubbed with
  `Req.Test` in the suite.
  """

  alias TravelingPoet.Accounts.User
  alias TravelingPoet.GoogleAuth

  @events_url "https://www.googleapis.com/calendar/v3/calendars/primary/events"
  @page_size 250
  @max_pages 4

  def scope, do: GoogleAuth.scope(:calendar)

  def connected?(user), do: GoogleAuth.connected?(user, :calendar)

  @doc """
  Every event on the primary calendar between `from` and `to` (dates, `to`
  exclusive), recurring ones expanded. Returns `{:ok, events, user}` (the
  user carries a refreshed access token), `{:error, :reconnect}` when the
  grant is gone, `{:error, :forbidden}` when Google refuses the calendar,
  or `{:error, reason}`.
  """
  def list_events(%User{} = user, %Date{} = from, %Date{} = to) do
    with {:ok, user, token} <- GoogleAuth.access_token(user),
         {:ok, items} <- pages(token, from, to, nil, [], 0) do
      {:ok, items |> Enum.map(&normalize_event/1) |> Enum.reject(&is_nil/1), user}
    end
  end

  defp pages(_token, _from, _to, _page_token, acc, @max_pages), do: {:ok, acc}

  defp pages(token, from, to, page_token, acc, page) do
    params =
      [
        timeMin: "#{Date.to_iso8601(from)}T00:00:00Z",
        timeMax: "#{Date.to_iso8601(to)}T00:00:00Z",
        singleEvents: true,
        orderBy: "startTime",
        maxResults: @page_size,
        showDeleted: false
      ] ++ if(page_token, do: [pageToken: page_token], else: [])

    case Req.get(
           @events_url,
           [auth: {:bearer, token}, params: params] ++ GoogleAuth.req_options()
         ) do
      {:ok, %{status: 200, body: %{} = body}} ->
        acc = acc ++ List.wrap(body["items"])

        case body["nextPageToken"] do
          nil -> {:ok, acc}
          next -> pages(token, from, to, next, acc, page + 1)
        end

      {:ok, %{status: 401}} ->
        {:error, :reconnect}

      {:ok, %{status: 403}} ->
        {:error, :forbidden}

      {:ok, %{status: status, body: body}} ->
        {:error, {:calendar, "HTTP #{status}: #{inspect(body) |> String.slice(0, 200)}"}}

      {:error, reason} ->
        {:error, {:calendar, inspect(reason) |> String.slice(0, 200)}}
    end
  end

  @doc """
  One Calendar API event as the detector reads it: `%{id, ical_uid, status,
  summary, location, event_type, all_day?, start_on, end_on}`. All-day
  events end on the day before Google's exclusive end date; timed events
  take the local calendar date of their own timezone. Cancelled events, and
  events with no usable dates, are nil.
  """
  def normalize_event(%{"status" => "cancelled"}), do: nil

  def normalize_event(%{} = item) do
    all_day? = is_map(item["start"]) and is_binary(item["start"]["date"])

    with {:ok, start_on} <- boundary(item["start"], all_day?, :start),
         {:ok, end_on} <- boundary(item["end"], all_day?, :end) do
      %{
        id: item["id"],
        ical_uid: item["iCalUID"],
        status: item["status"] || "confirmed",
        summary: item["summary"],
        location: item["location"],
        event_type: item["eventType"] || "default",
        all_day?: all_day?,
        start_on: start_on,
        end_on: Enum.max([start_on, end_on], Date)
      }
    else
      _ -> nil
    end
  end

  def normalize_event(_), do: nil

  defp boundary(%{"date" => date}, true, side) when is_binary(date) do
    with {:ok, day} <- Date.from_iso8601(date) do
      {:ok, if(side == :end, do: Date.add(day, -1), else: day)}
    end
  end

  defp boundary(%{"dateTime" => at}, false, _side) when is_binary(at),
    do: at |> String.slice(0, 10) |> Date.from_iso8601()

  defp boundary(_, _, _), do: :error
end
