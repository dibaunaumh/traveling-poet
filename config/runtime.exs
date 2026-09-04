import Config

# Load .env file if it exists (dev convenience; prod uses Fly secrets)
if File.exists?(".env") do
  for line <- File.stream!(".env") do
    line = String.trim(line)

    unless String.starts_with?(line, "#") or line == "" do
      case String.split(line, "=", parts: 2) do
        [key, value] -> System.put_env(key, value)
        _ -> :ok
      end
    end
  end
end

if System.get_env("GOOGLE_CLIENT_ID") do
  config :ueberauth, Ueberauth.Strategy.Google.OAuth,
    client_id: System.get_env("GOOGLE_CLIENT_ID"),
    client_secret: System.get_env("GOOGLE_CLIENT_SECRET")
end

config :traveling_poet,
  phoenix_url: System.get_env("PHOENIX_URL", "http://localhost:4000"),
  sprites_api_url: System.get_env("SPRITES_API_URL", "https://api.sprites.dev/v1"),
  sprites_token: System.get_env("SPRITES_TOKEN"),
  sprite_namespace: System.get_env("SPRITE_NAMESPACE"),
  openclaw_stable_version: System.get_env("OPENCLAW_STABLE_VERSION", "2026.4.9"),
  # nil in test: .env loads in every env, and a live key would let tests hit
  # the real OpenRouter API (text or image) and spend money
  openrouter_api_key:
    if(config_env() == :test, do: nil, else: System.get_env("OPENROUTER_API_KEY")),
  # Pinned in test for the same reason the keys above are: runtime.exs loads
  # .env in every env, so whatever the fleet happens to run today would
  # otherwise decide what the model-policy tests assert. Two distinct values so
  # "scout beats fleet default" is a real assertion rather than a tautology.
  openrouter_model:
    if(config_env() == :test,
      do: "test/fleet-model",
      else: System.get_env("OPENROUTER_MODEL", "anthropic/claude-sonnet-4.6")
    ),
  scout_model:
    if(config_env() == :test,
      do: "test/scout-model",
      else: System.get_env("SCOUT_MODEL", "anthropic/claude-sonnet-4.6")
    ),
  # image generation rides the OpenRouter key (Illustrations module);
  # IMAGE_GEN_API_KEY no longer exists
  image_gen_model: System.get_env("IMAGE_GEN_MODEL", "google/gemini-2.5-flash-image"),
  # Used only by the one-off places backfill. Pinned in test for the same
  # reason the model slugs above are: .env loads in every env, so whatever the
  # fleet happens to run today must not decide what the tests assert.
  extraction_model:
    if(config_env() == :test,
      do: "test/extraction-model",
      else: System.get_env("EXTRACTION_MODEL", "google/gemini-2.5-flash")
    ),
  # nil in test: runtime.exs loads .env in every env, and a real token here
  # would boot the Telegram Poller/Notifier inside the test run — they'd hit
  # the DB outside the sandbox and lock-jam SQLite (learned the hard way)
  telegram_bot_token:
    if(config_env() == :test, do: nil, else: System.get_env("TELEGRAM_BOT_TOKEN")),
  telegram_bot_username: System.get_env("TELEGRAM_BOT_USERNAME"),
  # Web Push (installed PWA / desktop notifications). Pinned in test so the
  # UI can be exercised whatever .env holds; the Notifier itself is switched
  # off in test (below) so a publish in the suite never leaves the sandbox.
  vapid_public_key:
    if(config_env() == :test,
      do:
        "BMLBb4sHn_gvlf8Tjjb3s67P6sEpq3lmwcNxGaM_ybj797EP8LK1omJUwB7an81116-exLbP_cNFqq0DuFwfPgg",
      else: System.get_env("VAPID_PUBLIC_KEY")
    ),
  vapid_private_key:
    if(config_env() == :test,
      do: "xqbjScFfhUpMTyfRYyABdl90i2cCwBTii1E7Cz2XHWY",
      else: System.get_env("VAPID_PRIVATE_KEY")
    ),
  # Contact the push services may use about our traffic; a URL is valid too.
  vapid_subject: System.get_env("VAPID_SUBJECT"),
  web_push_notifier: config_env() != :test,
  tigris_bucket_name: System.get_env("TIGRIS_BUCKET_NAME"),
  journey_check_interval_minutes:
    if(config_env() == :test,
      do: 0,
      else: String.to_integer(System.get_env("JOURNEY_CHECK_INTERVAL_MINUTES") || "0")
    ),
  # Missed-day watchdog: same test-env reasoning as the journey scheduler
  fleet_health_check_interval_minutes:
    if(config_env() == :test,
      do: 0,
      else: String.to_integer(System.get_env("FLEET_HEALTH_CHECK_INTERVAL_MINUTES") || "0")
    ),
  alert_telegram_chat_id: System.get_env("ALERT_TELEGRAM_CHAT_ID"),
  # First-entry retries. On by default (5m): unlike the schedulers above this
  # one is the difference between a new poet publishing and sitting silent
  # until tomorrow, so it should not need a secret set to work.
  first_entry_check_interval_minutes:
    if(config_env() == :test,
      do: 0,
      else: String.to_integer(System.get_env("FIRST_ENTRY_CHECK_INTERVAL_MINUTES") || "5")
    ),
  # Change stream (webhook mirror for external operator agents). Poll 0 in
  # test: the suite drives Capture.tick/1 and Delivery.deliver_pending/1
  # directly, and a live Worker would race the sandbox.
  change_stream_poll_seconds:
    if(config_env() == :test,
      do: 0,
      else: String.to_integer(System.get_env("CHANGE_STREAM_POLL_SECONDS") || "30")
    ),
  change_stream_batch_size:
    String.to_integer(System.get_env("CHANGE_STREAM_BATCH_SIZE") || "100"),
  change_stream_max_batch_wait_seconds:
    String.to_integer(System.get_env("CHANGE_STREAM_MAX_BATCH_WAIT_SECONDS") || "60"),
  change_stream_failure_threshold:
    String.to_integer(System.get_env("CHANGE_STREAM_FAILURE_THRESHOLD") || "5"),
  daily_runs_cap: String.to_integer(System.get_env("DAILY_RUNS_CAP") || "1"),
  daily_chat_turns_cap: String.to_integer(System.get_env("DAILY_CHAT_TURNS_CAP") || "50"),
  daily_image_cap: String.to_integer(System.get_env("DAILY_IMAGE_CAP") || "6"),
  # false in test: Nominatim needs no API key, so unlike every other service
  # here there is nothing to nil out. Without this switch the suite would make
  # live OSM requests -- slow, flaky, and a good way to get the app's
  # User-Agent banned, which would break onboarding for real users.
  geocoding_enabled: config_env() != :test,
  # OSM policy is 1 req/s for the whole app. The Limiter enforces it.
  geocode_min_interval_ms: String.to_integer(System.get_env("GEOCODE_MIN_INTERVAL_MS") || "1100"),
  # How long a "never heard of it" answer stays cached before we ask again.
  geocode_miss_ttl_days: String.to_integer(System.get_env("GEOCODE_MISS_TTL_DAYS") || "30"),
  # Credits: whole credits per daily run by mission; welcome grant; alert
  # threshold in days of runway
  credit_rates: %{
    "wander" => String.to_integer(System.get_env("CREDIT_RATE_WANDER") || "1"),
    "scout" => String.to_integer(System.get_env("CREDIT_RATE_SCOUT") || "5")
  },
  signup_credits: String.to_integer(System.get_env("SIGNUP_CREDITS") || "10"),
  low_credits_days: String.to_integer(System.get_env("LOW_CREDITS_DAYS") || "3"),
  # nil in test so a live key in .env can never reach Stripe from the suite
  stripe_secret_key:
    if(config_env() == :test, do: nil, else: System.get_env("STRIPE_SECRET_KEY")),
  stripe_webhook_secret:
    if(config_env() == :test, do: nil, else: System.get_env("STRIPE_WEBHOOK_SECRET"))

# Real Stripe checkout only when both secrets are present; otherwise the
# clearly-labelled mock pay page (dev/test).
stripe_configured? =
  config_env() != :test and
    System.get_env("STRIPE_SECRET_KEY") not in [nil, ""] and
    System.get_env("STRIPE_WEBHOOK_SECRET") not in [nil, ""]

config :traveling_poet,
       :payments_provider,
       if(stripe_configured?,
         do: TravelingPoet.Payments.Stripe,
         else: TravelingPoet.Payments.Mock
       )

# Tigris (S3-compatible) — same env names alice-in / Fly's Tigris extension use
if System.get_env("AWS_ACCESS_KEY_ID") do
  config :ex_aws,
    access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
    s3: [
      scheme: "https://",
      host:
        System.get_env("AWS_ENDPOINT_URL_S3", "fly.storage.tigris.dev")
        |> String.replace(~r{^https?://}, ""),
      region: System.get_env("AWS_REGION", "auto")
    ]
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/traveling_poet start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :traveling_poet, TravelingPoetWeb.Endpoint, server: true
end

config :traveling_poet, TravelingPoetWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/traveling_poet/traveling_poet.db
      """

  config :traveling_poet, TravelingPoet.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :traveling_poet, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # The app answers on both the custom domain (PHX_HOST) and the Fly-provided
  # hostname; allow LiveView websockets from both so the fly.dev URL keeps
  # working as a fallback after the domain switch.
  extra_origins =
    case System.get_env("FLY_APP_NAME") do
      nil -> []
      app -> ["https://#{app}.fly.dev"]
    end

  config :traveling_poet, TravelingPoetWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: ["https://#{host}" | extra_origins],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :traveling_poet, TravelingPoetWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :traveling_poet, TravelingPoetWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
