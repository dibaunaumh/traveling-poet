defmodule TravelingPoet.NearHome.Away do
  @moduledoc """
  Away from home (card-78): when the reader's own device says they are far
  from home, Near you looks around where they are instead.

  The device reports only while the app or site is open, and only after the
  reader switched it on in Settings (`users.away_aware`); there is no
  background location. A report is rounded to about a kilometre and named
  by town (`Geocoder.reverse/2`). The reader is away while their last
  report is under `@fresh_days` old and more than `@away_km` from home, the
  same distance calendar trips count as a trip (`Trips.Detector`).

  Arriving somewhere new starts a Near you turn at once (`report/3`), not
  on the weekly cadence: a stay is short. Once per place a week: a batch
  found within `NearHome.radius_km/0` of here in the last seven days counts.
  The turn keeps every Near you gate (credits, the one-a-day cap, a busy
  sprite); a day it is refused, the next published page tries again
  (`NearHome.due?/2`).
  """

  import Ecto.Query
  require Logger

  alias TravelingPoet.{Accounts, Geo, NearHome, Poets, Repo}
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.NearHome.Pick

  @away_km 150
  @fresh_days 7
  # A report this close to the last one keeps its name: no geocoder call
  @same_place_km 10

  def away_km, do: @away_km

  @doc """
  Where the reader is, as Near you's anchor, when they are away from home:
  `%{name:, lat:, lng:, away?: true}`; nil when they are home, have no
  home, did not switch this on, or have not reported in `@fresh_days`.
  """
  def here(%User{} = user, now \\ DateTime.utc_now()) do
    with true <- user.away_aware == true,
         true <- NearHome.home?(user),
         lat when is_number(lat) <- user.here_lat,
         lng when is_number(lng) <- user.here_lng,
         %DateTime{} = at <- user.here_at,
         true <- DateTime.diff(now, at, :day) < @fresh_days,
         true <- Geo.distance_km(lat, lng, user.home_lat, user.home_lng) > @away_km do
      %{name: user.here_place_name, lat: lat, lng: lng, away?: true}
    else
      _ -> nil
    end
  end

  @doc """
  Whether Near you should look around where the reader is now: they are
  away, and no batch of the last seven days was found around here.
  """
  def due?(%User{} = user, %Date{} = today \\ Date.utc_today()) do
    case here(user) do
      nil -> false
      here -> not looked_around?(user.id, here, today)
    end
  end

  defp looked_around?(user_id, here, today) do
    since = Date.add(today, -6)

    Pick
    |> where([p], p.user_id == ^user_id and p.week_of >= ^since and not is_nil(p.around_lat))
    |> select([p], {p.around_lat, p.around_lng})
    |> distinct(true)
    |> Repo.all()
    |> Enum.any?(fn {lat, lng} ->
      Geo.distance_km(lat, lng, here.lat, here.lng) <= NearHome.radius_km()
    end)
  end

  @doc """
  The reader's device says they are at `lat`, `lng`. Stores it (rounded),
  names the town when it is a new place, and starts a Near you turn when
  they are away somewhere Near you has not looked yet.

  Returns `{:ok, %{away?:, place:, here:, looking?:}}` (`here` as `here/2`), or `{:error, :off}` when
  the reader has not switched it on, `{:error, :invalid}` for a point that
  is not one.
  """
  def report(%User{} = user, lat, lng, now \\ DateTime.utc_now()) do
    cond do
      user.away_aware != true ->
        {:error, :off}

      not valid?(lat, lng) ->
        {:error, :invalid}

      true ->
        lat = Float.round(lat / 1, 2)
        lng = Float.round(lng / 1, 2)

        {:ok, user} =
          Accounts.update_user(user, %{
            here_lat: lat,
            here_lng: lng,
            here_place_name: place_name(user, lat, lng),
            here_at: DateTime.truncate(now, :second)
          })

        here = here(user, now)
        looking? = here != nil and look(user)

        {:ok, %{away?: here != nil, place: here && here.name, here: here, looking?: looking?}}
    end
  end

  @doc "Switches noticing on or off; off forgets where the reader was."
  def set_enabled(%User{} = user, true), do: Accounts.update_user(user, %{away_aware: true})

  def set_enabled(%User{} = user, false) do
    Accounts.update_user(user, %{
      away_aware: false,
      here_lat: nil,
      here_lng: nil,
      here_place_name: nil,
      here_at: nil
    })
  end

  # A Near you turn around here, when one is due; true while the poet looks.
  defp look(user) do
    poet = user.onboarding_completed && Poets.get_poet_by_user(user.id)

    cond do
      !poet ->
        false

      NearHome.looking?(user.id) ->
        true

      due?(user) ->
        case NearHome.request(user, poet) do
          {:ok, :started} ->
            true

          {:error, reason} ->
            Logger.info("NearHome.Away: poet #{poet.id} not asked: #{reason}")
            false
        end

      true ->
        false
    end
  end

  defp place_name(user, lat, lng) do
    if same_place?(user, lat, lng) do
      user.here_place_name
    else
      reverse =
        Application.get_env(:traveling_poet, :reverse_geocoder, &TravelingPoet.Geocoder.reverse/2)

      case reverse.(lat, lng) do
        {:ok, %{city: city, country: country}} when is_binary(city) ->
          Enum.join(Enum.reject([city, country], &(&1 in [nil, ""])), ", ")

        {:ok, %{country: country}} when is_binary(country) ->
          country

        _ ->
          nil
      end
    end
  end

  defp same_place?(%User{here_lat: lat, here_lng: lng, here_place_name: name}, new_lat, new_lng)
       when is_number(lat) and is_number(lng) and is_binary(name),
       do: Geo.distance_km(lat, lng, new_lat, new_lng) <= @same_place_km

  defp same_place?(_user, _lat, _lng), do: false

  defp valid?(lat, lng),
    do:
      is_number(lat) and is_number(lng) and lat >= -90 and lat <= 90 and lng >= -180 and
        lng <= 180

  @doc "A place's short name for headings: \"Tel Aviv-Yafo\" of \"Tel Aviv-Yafo, Israel\"."
  def short_name(nil), do: nil
  def short_name(name), do: name |> String.split(",") |> hd() |> String.trim()

  @doc """
  What to call a place on screen: its short name, or its coordinates when
  the town could not be named (the next report tries again).
  """
  def display_name(name, lat, lng) do
    short_name(name) ||
      "#{:erlang.float_to_binary(lat / 1, decimals: 2)}, #{:erlang.float_to_binary(lng / 1, decimals: 2)}"
  end
end
