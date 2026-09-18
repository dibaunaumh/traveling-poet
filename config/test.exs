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
config :traveling_poet, web_push_req_options: [plug: {Req.Test, TravelingPoet.WebPush}]
# Link liveness probes (LinkCheck) too: a test that cites a URL stubs the
# answer, so no assertion ever depends on a real site being up.
config :traveling_poet, link_check_req_options: [plug: {Req.Test, TravelingPoet.LinkCheck}]
# Image generation (Illustrations) and the eval judge: an unstubbed OpenRouter
# call raises
config :traveling_poet, illustrations_req_options: [plug: {Req.Test, TravelingPoet.Illustrations}]
config :traveling_poet, eval_req_options: [plug: {Req.Test, TravelingPoet.Evals}]
# Wikimedia Commons lookups (find_reference_photos) too
config :traveling_poet, commons_req_options: [plug: {Req.Test, TravelingPoet.Commons}]

# Onboarding and mode switches provision the sprite in a background task.
# Never do that from the test suite: with SPRITES_TOKEN/OPENROUTER_API_KEY in
# the shell it would create a real sprite, and the task runs outside the
# sandbox owner anyway.
config :traveling_poet, provision_in_background: false

# A composition request charges and opens the edition, then fires the poet's
# turn in a task. Never from the suite: the turn would try to wake a sprite.
# Tests drive Books.Composer.finish/2 directly with the outcome they need.
config :traveling_poet, book_compose_in_background: false

# A PDF request opens the row, then renders on the poet's sprite in a task
# and uploads to Tigris. Never from the suite: tests drive
# Books.PdfRenderer.run/1 with a fake runner and storage.
config :traveling_poet,
  book_pdf_in_background: false,
  book_pdf_runner: TravelingPoet.FakePdfRunner,
  book_pdf_storage: TravelingPoet.FakePdfStorage,
  book_pdf_poll_ms: 0

# Google: every request (token, revoke, Drive) through Req.Test, the Drive
# save runs inline when a test calls Books.run_drive_save/2, and PDF bytes
# never come from the bucket.
config :traveling_poet,
  google_req_options: [plug: {Req.Test, TravelingPoet.Google}],
  book_drive_in_background: false,
  # a calendar sync after connect or "Check now" runs inline
  calendar_sync_in_background: false,
  book_pdf_bytes: &TravelingPoet.FakePdfStorage.bytes/1

# Visit-event pruning runs on a timer; tests call Analytics.prune/1 directly.
config :traveling_poet, analytics_prune: false
