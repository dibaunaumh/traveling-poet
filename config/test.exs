import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :traveling_poet, TravelingPoet.Repo,
  database: Path.expand("../traveling_poet_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :traveling_poet, TravelingPoetWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "M2qkwmjPYXDsR3iGpn9I8AoJZixmr+YnxRtW/3cbT8aBuTP9SRghf2w/6pUdek4v",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Every change-stream POST goes through Req.Test; an unstubbed call raises
# instead of reaching a network. There is no other seam — the app has no
# HTTP mocking library.
config :traveling_poet, change_stream_req_options: [plug: {Req.Test, TravelingPoet.ChangeStream}]

# Onboarding and mode switches provision the sprite in a background task.
# Never do that from the test suite: with SPRITES_TOKEN/OPENROUTER_API_KEY in
# the shell it would create a real sprite, and the task runs outside the
# sandbox owner anyway.
config :traveling_poet, provision_in_background: false
