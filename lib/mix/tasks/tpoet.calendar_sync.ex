defmodule Mix.Tasks.Tpoet.CalendarSync do
  @shortdoc "Reads one companion's Google Calendar for upcoming trips, now"

  @moduledoc """
  Runs one calendar sync outside the schedule, for a companion by email:

      mix tpoet.calendar_sync udi@example.com

  Prints what was found, updated and withdrawn. This is a wrapper around
  `TravelingPoet.Trips.CalendarSync.sync_user/1`; in production, where
  there is no Mix, call that over rpc:

      bin/traveling_poet rpc 'TravelingPoet.Trips.CalendarSync.sync_user(TravelingPoet.Repo.get_by(TravelingPoet.Accounts.User,email:\\"x@y.z\\"))'

  Geocoding goes through the app-wide limiter; a first sync with many new
  locations takes a little while.
  """

  use Mix.Task

  alias TravelingPoet.{Repo, Trips}
  alias TravelingPoet.Accounts.User

  @impl true
  def run([email]) do
    Mix.Task.run("app.start")

    case Repo.get_by(User, email: email) do
      nil ->
        Mix.raise("No user with email #{email}")

      user ->
        case Trips.CalendarSync.sync_user(user) do
          {:ok, %{new: new, updated: updated, withdrawn: withdrawn}} ->
            Mix.shell().info(
              "Synced #{email}: #{length(new)} new, #{updated} updated, #{withdrawn} withdrawn"
            )

            for trip <- new do
              Mix.shell().info(
                "  #{trip.name}: #{Trips.date_range(trip.start_date, trip.end_date)}"
              )
            end

          {:error, reason} ->
            Mix.raise("Sync failed: #{inspect(reason)}")
        end
    end
  end

  def run(_args), do: Mix.raise("usage: mix tpoet.calendar_sync EMAIL")
end
