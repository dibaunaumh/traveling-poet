defmodule TravelingPoet.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TravelingPoetWeb.Telemetry,
      TravelingPoet.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:traveling_poet, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:traveling_poet, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TravelingPoet.PubSub},
      {Registry, keys: :unique, name: TravelingPoet.GatewayRegistry},
      {DynamicSupervisor, name: TravelingPoet.GatewaySocketSupervisor, strategy: :one_for_one},
      # Daily travel/journal driver (no-op unless JOURNEY_CHECK_INTERVAL_MINUTES > 0)
      # Serializes every Nominatim call to OSM's 1 req/s policy. Onboarding and
      # settings geocode on submit too, so a ban would break signup itself.
      TravelingPoet.Geocoder.Limiter,
      TravelingPoet.DailyJourneyScheduler,
      # Telegram long-poller + publish notifier (no-op unless TELEGRAM_BOT_TOKEN set)
      TravelingPoet.Telegram.Poller,
      TravelingPoet.Telegram.Notifier,
      # Missed-day watchdog (no-op unless FLEET_HEALTH_CHECK_INTERVAL_MINUTES > 0)
      TravelingPoet.FleetHealth.Alerter,
      # Webhook mirror of the DB (no-op unless CHANGE_STREAM_POLL_SECONDS > 0
      # AND an endpoint is registered)
      TravelingPoet.ChangeStream.Worker,
      # Retries first-entry kickoffs so a closed tab can't strand a new poet
      TravelingPoet.FirstEntry.Watchdog,
      # Start to serve requests, typically the last entry
      TravelingPoetWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TravelingPoet.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TravelingPoetWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
