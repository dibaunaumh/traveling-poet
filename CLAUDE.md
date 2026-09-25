# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Traveling Poet (poet.travel): each user gets an AI "poet" that travels virtually through real places and publishes a daily illustrated journal entry. The poet is an OpenClaw agent running in a per-user sprites.dev sandbox; this Phoenix app provisions it, drives it, and renders what it writes.

`AGENTS.md` at the repo root holds the generic Phoenix 1.8 / LiveView / Ecto / Tailwind v4 conventions (Layouts.app wrapping, `<.input>`, streams, form handling, `mix precommit`). Follow it; this file covers only what is specific to this project.

## Commands

```bash
mix setup                      # deps, DB create+migrate, tailwind/esbuild install+build
mix phx.server                 # http://localhost:4000 (or iex -S mix phx.server)
mix precommit                  # compile --warnings-as-errors, unused deps, format, test. Run before finishing.
mix test                       # runs ecto.create/migrate first (aliased)
mix test test/traveling_poet/credits_test.exs        # one file
mix test test/traveling_poet/credits_test.exs:42     # one test
mix format
```

Project Mix tasks (see each module's moduledoc for flags):

```bash
mix tpoet.smoke_poet [--teardown]      # real sprite + OpenClaw + gateway + model round-trip; needs SPRITES_TOKEN, OPENROUTER_API_KEY
mix tpoet.delete_user EMAIL [--yes]    # irreversible purge of a user (account, poet, journal, media, ledger, sprite)
mix tpoet.backfill_places [--commit]   # extract trip-guide places from old entries; DRY RUN by default
mix tpoet.gen_vapid_keys               # generate once, keep forever (rotation kills every push subscription)
mix tpoet.calendar_sync EMAIL          # one Google Calendar trip sync now; prod: rpc Trips.CalendarSync.sync_user/1
```

Dev-only sign-in without Google: `GET /dev/login/:user_id` (`DevSessionController`, routed only under `dev_routes`) starts a session for that user and lands on `/journal`. Handy for owner pages such as the pre-first-entry journal, which needs a signed-in owner with a poet.

Deploy and prod ops:

```bash
./deploy.sh dev            # fly deploy of fly.dev.toml -> app traveling-poet-dev. This IS production (poet.travel). There is no fly.prod.toml.
fly ssh console -c fly.dev.toml -C "/app/bin/traveling_poet rpc 'TravelingPoet.Accounts.Purge.purge_by_email(\"x@y.z\")'"
```

Releases have no Mix, so anything that must run in prod lives in a plain module callable over `rpc` (e.g. `Guide.Backfill.run/1`, `ChangeStream.Backfill.run/1`, `Accounts.Purge`); the Mix tasks are thin local wrappers. Use `rpc`, not `eval` (`eval` boots a fresh node without the Repo). The `-C` string is re-parsed by a remote shell: write the Elixir expression with no spaces, no semicolons, escape every double quote as `\"`, and use `Map.new([{:k,v}])` instead of map or keyword literals.

Migrations run automatically on boot (`Ecto.Migrator` in the supervision tree) when `RELEASE_NAME` is set.

## Environment and config

- `config/runtime.exs` loads `.env` in EVERY env, including test. Copy `.env.example` to `.env`. Because of that, runtime.exs pins or nils out every external-service setting in `:test` (OpenRouter key, Telegram token, Stripe keys, model slugs, scheduler intervals, geocoding). When adding a new external integration, add the same test guard there, or the suite will spend money or hit the network.
- Outbound HTTP is `Req` only. In test, change-stream and web-push requests go through `Req.Test` stubs (`config/test.exs`); an unstubbed call raises. There is no other HTTP mocking library.
- `provision_in_background: false` in test. Onboarding provisions synchronously in the suite.
- Payments provider is chosen at boot: `Payments.Stripe` when both Stripe secrets exist, else `Payments.Mock` (an in-app fake pay page). Stripe fulfilment happens in the webhook, idempotent on session id.
- Model policy: one OpenRouter key for the whole fleet. `OPENROUTER_MODEL` is the default, `SCOUT_MODEL` overrides for scout-mode poets, `IMAGE_GEN_MODEL` for illustrations with `SPOT_IMAGE_MODEL` for spot drawings (`Illustrations.model_for/1`; image-only models answer on OpenRouter's Image API, not chat completions), `SEARCH_MODEL` for every poet's `web_search`, `EXTRACTION_MODEL` for the places backfill and the place topic classifier. Test env pins distinct fake slugs so policy tests are real assertions.

## Architecture

### The app is the driver, the sprite is the writer

The Phoenix app never writes journal prose itself. Its only server-side text LLM calls label what poets already wrote: `Guide.Extractor` (places backfill) and `Guide.PlaceClassifier` (subject-tree topics for places, and with its `:things` instructions for excursion finds and readers' topics and tastes, so all three share one set of coordinates). Everything the poet writes happens on its sprite.

- `Provisioner` creates the sprite, installs OpenClaw, writes `~/.openclaw/openclaw.json` and `.env`, seeds the workspace from `priv/data/` (AGENTS.md, BOOTSTRAP.md, HEARTBEAT.md, `skills/*/SKILL.md`), generates and installs the `tpoet-plugin` (the agent's tool set, source in `Provisioner.tpoet_plugin_source/2`), starts the gateway, and pairs an Ed25519 device. Idempotent. The OpenClaw heartbeat is disabled in `Provisioner.openclaw_config/3` (a paused sprite has no clock; all cadence is app-side) and `AgentSession` ignores a `HEARTBEAT_OK` reply. `Provisioner.upgrade_workspace/1` rewrites openclaw.json and re-seeds workspace + plugin for one poet; `Provisioner.upgrade_fleet/1` rolls that across every provisioned poet, staggered.
- `priv/data/**` is read at compile time; editing a SKILL.md or `poet_presets.json` needs `mix compile --force` before the change is picked up.
- The plugin's tools call back into `/api/agent/*` (bearer token = `users.agent_api_token`, shape `<user_id>.<secret>`, verified by `Plugs.AgentAuth`). Tool handlers must have arity `(toolCallId, params)`; `agent_plugin_test.exs` pins this because a one-arg handler silently receives the call id as its body.
- `GatewaySocket` (WebSockex, `restart: :temporary`) is the WebSocket client into a sprite's OpenClaw gateway. It is started on demand via `GatewaySocketSupervisor.ensure_connected/1` and closes itself when idle, because an open socket keeps the sprite awake and billing. Never make it permanent.
- `AgentSession` is the headless exchange (wake sprite, send, hold awake, collect streamed reply, persist to `Chat`) used by everything that talks to a poet without a browser: the daily scheduler, first-entry kickoff, Telegram relay.
- `SpriteHold` keeps a sprite running while the app drives it, via the Sprites Tasks API (`/.sprite/api.sock`, reachable only inside the sprite, so each call is one short `curl` over `SpritesClient.exec`). `with_hold/4` creates a uniquely named task, refreshes it while the turn runs, and deletes it after. Do not reintroduce long `sleep` execs as a hold.

### Background processes (all in `Application`, all no-op unless configured)

| Process | Env switch | Purpose |
|---|---|---|
| `DailyJourneyScheduler` | `JOURNEY_CHECK_INTERVAL_MINUTES` | Fires `/travel-and-journal` at due poets; a run counts only if the poet actually published; max 3 attempts/day |
| `FirstEntry.Watchdog` | `FIRST_ENTRY_CHECK_INTERVAL_MINUTES` (default 5) | Retries `/onboard` until the first entry is published |
| `Markers.Watchdog` | `MARKER_DELIVERY_INTERVAL_MINUTES` (+ `MARKER_QUIET_MINUTES`, default 15) | Sends the reader's feedback markers to the poet as one `/revise-entry` turn once the reader has been quiet |
| `FleetHealth.Alerter` | `FLEET_HEALTH_CHECK_INTERVAL_MINUTES` | Pages admins over Telegram about poets that stopped publishing; also surfaces `OpenRouter.key_status` because an exhausted key looks like a silent sprite |
| `ChangeStream.Worker` | `CHANGE_STREAM_POLL_SECONDS` + a registered endpoint | Snapshot-diff outbox + signed webhook delivery for external agents |
| `Trips.CalendarSync` | `CALENDAR_SYNC_INTERVAL_MINUTES` (+ `CALENDAR_ENABLED`: admins / all / off) | Reads connected Google Calendars, runs the pure `Trips.Detector` over the events, and stores trip suggestions via `Trips.reconcile/4`; tests call `sync_user/1` |
| `Telegram.Poller` / `Telegram.Notifier` | `TELEGRAM_BOT_TOKEN` | Pairing, chat relay, publish notes |
| `WebPush.Notifier` | VAPID keys | Browser push on publish |
| `Geocoder.Limiter` | always on | Serialises every Nominatim call to 1 req/s app-wide. All geocoding must go through it |

Operator paging goes through `Alerts.notify_admins/1` (`ALERT_TELEGRAM_CHAT_ID`, else every admin who paired Telegram). Callers compose and dedup; it only sends.

The app runs on exactly ONE Fly machine (SQLite on a volume, single Telegram poller, in-process schedulers). Never scale horizontally, and never set `min_machines_running` to 0.

### PubSub topics

- `"user:#{user_id}"`: `{:sprite_provisioned, ...}`, credit changes, Telegram pairing.
- `"poet:#{poet_id}"`: `{:journal_published, entry_id}`, geocoding results; subscribed by owner and public journal/guide LiveViews.
- `"journal:published"`: `{:journal_published, poet_id, entry_id}` for cross-cutting listeners (notifiers, landing map).
- `"credits:low"`.
- `"trips"`: `{:trip_suggested, user_id, trip_id}` for the notifiers; `{:trips_updated}` goes on the user topic.
- `"admin_events"`: `{:user_signed_up, user_id, identity}` and `{:credits_purchased, transaction_id}` (new purchases only, never a replay); `Telegram.Notifier` pages the admins through `Alerts.notify_admins/1`.
- `"asks"`: `{:reader_asked, user_id, ask_id}` for the notifiers (push, APNs, Telegram); `{:poet_asked, chat_message}` goes on the user topic so an open chat shows it.

### Contexts worth knowing before touching them

- `Journal` (entries, typed sections, media, reactions) vs `Guide` (places with geocoded pins and poet ratings). Keep places OUT of `journal_sections`: `replace_sections/2` wipes and re-inserts on every agent re-put and would destroy coordinates and drawings.
- Place topics (the global village): `Guide.PlaceTopics` is a fixed 3-level tree, by subject, in `priv/data/place_topics.json` (approved by Udi; grows only on purpose). A place stores up to two third-level paths (`topic`, `second_topic`), a `place_type`, and `topics_classified_at`; ancestors by path prefix. The app classifies, never the poet: `Guide.TopicTagging.tag_entry_async/1` after `journal_put_places`, and `TopicTagging.backfill/1` over `rpc` (dry run unless `commit: true`). `replace_places/2` carries topics over by name. Not the same thing as `Topics` (a companion's excursion subjects).
- Rendering is defensive about what the model fumbles. `Journal.Spreads` (pure) lays an entry across the Today and Places spreads and draws any media linked to the entry that no section claimed; `Journal.Spots.embed_unclaimed/2` weaves spot drawings no body embeds into the prose at render time. Neither touches the stored body. `NotebookComponents.raw_markdown/3` is the only section renderer: it sanitizes, drops every image that is not an app `/media/:id` the caller vouched for, and links the first mention of each place to its stop by splitting Text nodes only, so feedback-marker text offsets stay byte-exact. Keep it that way when changing it.
- The app counts, the poet never does: `Journal.journey_day/1` (calendar days since the first published entry), `Poets.visited_stays/1` + `returning?/1` (journey memory so a wanderer does not bounce back), and `drawings.spots` (how many spot drawings today gets, from the companion's verbosity) are all computed app-side and handed to the agent in `/api/agent/context`. The poet writes the entry `teaser` at upsert; it is cut to 140 chars on a word boundary, never rejected.
- `Markers.Guard` keeps a revision surgical: when a published entry with active markers (pending, or sent in the last 30 min) is re-put, every section no change-asking marker sits on is restored from the stored version, and the endpoint replies `kept_as_written`. Praise markers (Interesting, Beautiful) ask for nothing. Chat-requested revisions with no markers in play pass through.
- `Preferences` learns what the companion wants from taps, chat, reactions and settings, with decay and sticky dismissal. The agent may only ADD preferences (source forced to `"chat"`), never delete. `Preferences.Cadence` decides when to ask; the app owns that decision, not the model.
- A topic is a subject, or a taste when `poet_topics.domain` is set (music, books, film_tv, outdoors, gifts; the label is the reader's taste in their words). A taste's excursion day is a discovery of new things that fit it (skill 2d; `past_finds` keeps it from repeating), with find kinds music/book/screen/outing grouped as "works" in the Guide. `Asks.Cadence` asks about one domain a week once a reader has a topic, then monthly.
- `Journal.Paragraphs` splits an entry's prose sections into paragraphs keyed by a hash of their visible text (the browser computes the same key from a rendered `<p>`), and `paragraph_subjects` puts each on the subject tree, tagged on every publish (`TopicTagging.tag_paragraphs_async/1`; a revision tags only the paragraphs it changed). It is the base of the reader's taste profile (card-49).
- `Asks` is the one way the poet starts a conversation: on days `Asks.Cadence` picks (pure; `ask_reader` in the context), the poet calls its `ask_reader` tool after publishing, and the app stores the question, puts it in the chat and notifies. Any reader chat message counts as a reply (`Chat.create_message/1` calls `Asks.note_reader_message/1`). The reply itself reaches the poet headed by an app note naming the `ask_id` (`Asks.frame_reply/2`, in the web chat and the Telegram relay; the chat stores only the reader's words), because a poet left to find the ask read its day plan instead and wrote the day's excursion in a chat turn. A topic the poet takes from the answer (`propose_topic` with `ask_id`) is active at once, source `"ask"`; every other topic the poet proposes still waits in Settings.
- `Credits` is an append-only ledger in milli-credits; flat rate per daily run by mission (`wander`, `scout`). `Usage` holds the daily abuse caps. `quota_exempt` users are free.
- `Illustrations` generates images server-side via OpenRouter so no shared secret reaches the sprite; media lives in Tigris (S3) via `Storage.S3`, served through `/media/:id` which authorizes on `poet.is_public`. `DAILY_IMAGE_CAP` (prod 12) covers the main drawing, up to three spots, a place drawing and a revision. `LinkCheck` is a liveness gate on every agent-cited URL (sources, kindness links) with basic SSRF hygiene; the skill-side "only cite pages you fetched" rule covers the semantic half.
- `Discover` (with `DiscoverLive` and the `DiscoverMap` hook) is the one fleet view: `/discover`, and embedded compact (`live_render`) on the home page and on a new reader's journal while entry #0 is written. It has two views on one stage: World (Leaflet) and Village (`assets/js/village.js`, a zoomable treemap of `Discover.village/2`: places by subject, merged by name + city, unmapped ones included); a subject focused in the village filters the world map, and `?view=village&topic=` links into it. Private poets contribute a dot and nothing else; `Discover.blurred_point/1` is the one rule for how a private poet appears on any map (rounded to ~10km, nothing else).
- `Artifacts` / `SpriteUploads` move files out of and into a sprite's `~/.openclaw/workspace` over `SpritesClient.exec` (base64 through the shell, size-capped, path-validated). `GET /api/artifacts` serves them behind a 5-minute `SessionToken`. The `SessionToken` moduledoc still cites an `/api/generate_token` route that no longer exists.
- `ChangeStream.Registry` must list every Ecto schema as streamed or excluded; `registry_test.exs` fails the build otherwise. `Serializer` redacts by field name (anything token/secret/key-like, emails, chat content) and OMITS the key rather than masking it.
- `Accounts.Purge` relies on `on_delete: :delete_all` everywhere and `PRAGMA foreign_keys` being on. New tables hanging off `users` must cascade.
- `GoogleAuth` owns the ONE Google grant per account (`users.google_*` + `google_scopes`); Drive and Calendar are features of it. A feature's consent must ask for every scope the account already holds (Ueberauth only forwards `include_granted_scopes` from strategy options), and disconnecting a feature revokes with Google only when it was the last one. `Trips` is the calendar side: suggestions and plans are one `trips` row, accepted trips add `itinerary_stops` with `source: "trip"`, and `Trips.Detector` is pure (no Repo, no HTTP) so detection rules are unit-tested.

### The iOS app

The App Store app is a Capacitor shell in its own repo, `dibaunaumh/traveling-poet-ios`: one WKWebView that loads `https://poet.travel` (LiveView cannot be bundled, and `check_origin` only accepts the real origin), plus one local Swift plugin, `PoetNative`. Everything it needs from this app is here, and inert in a browser.

- **Detection**: the app signs requests with `TravelingPoetiOS/<version>` on the User-Agent. `Plugs.NativeApp` assigns `native_app` for controllers, `UserAuth.mount_current_user/2` for LiveViews (via `:user_agent` in the socket's `connect_info`), and the root layout marks `<html data-native="ios">`. The header only takes options away, so spoofing it gains nothing. `<html data-shell>` (set by an inline script, also for the home-screen web app) is what switches on the app's own navigation: `Layouts.shell_tabbar`, all CSS.
- **`assets/js/native.js`** is the page's side. There is no npm bundle, so it uses the two primitives Capacitor injects into every page, `nativePromise` and `addListener`; `Capacitor.Plugins.*` is NOT populated on a remote page. It owns link handling (other sites open in the in-app browser sheet, same-origin `target="_blank"` opens in place, the PDF goes through `?format=json`), both sign-in flows, settling StoreKit purchases, notification taps, and the window's appearance. A `fetch()` from page JS to a route in the `:browser` pipeline must not send `accept: application/json` (406 before the controller runs); tests should send `accept: */*` to catch that.
- **Google** refuses embedded web views, so sign-in and the Drive/Calendar consent trips run in the system sign-in sheet, which is Safari with its own cookie jar. `NativeAuth` hands the result across: a challenge parked in the sheet's session, a 60 second token on `travelpoet://auth`, and a CSRF-protected `POST /auth/native/handoff` with the verifier only the page holds (PKCE's idea). Connect outcomes come back as codes (`NativeAuth.connect_notice/1`) because a flash set in the sheet is never seen.
- **Sign in with Apple** is native and posts to `/auth/apple/native`; `Apple.IdentityToken` checks Apple's signature, `aud` = bundle id, and a nonce tied to the session. `Accounts.find_or_create_from_oauth/2` links identities on a provider-verified email, never on a Hide My Email relay address. All Apple signing (client secret, APNs) goes through `TravelingPoet.JWS` (`:crypto` and `:public_key`; there is no JOSE here) with the one `.p8` key: `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`, `APPLE_BUNDLE_ID`, all nil in test. Unset, the Apple button, APNs and revocation simply do not exist.
- **Credits in the app** are Apple In-App Purchase only (guideline 3.1.1; Stripe markup and `/credits/checkout` are absent there). `Payments.AppleIAP` trusts a StoreKit transaction only if its certificate chain leads to the pinned `priv/certs/AppleRootCA-G3.cer` and its `appAccountToken` is this user's; the ledger reference is `apple:<transactionId>`; the page finishes a transaction only after the server credited it. Production accepts `Sandbox` on purpose (App Review and TestFlight). Refunds arrive at `/webhooks/apple` and call `Credits.reverse_purchase/2`. Tests sign with `TravelingPoet.TestChain`.
- **Push in the app** is APNs (`TravelingPoet.Apns`, `apns_devices`): `WebPush.notify_user/2` builds each payload once and feeds both transports, and the opt-in UI and states are shared (`device` instead of `subscription`).
- **App Review scaffolding**: self-serve deletion in Settings (`Accounts.Purge` also revokes the Apple and Google grants), `/auth/review` (404 unless `REVIEW_LOGIN_EMAIL` and `REVIEW_LOGIN_PASSWORD_HASH` are set; see `ReviewLogin`), and an app-only AI consent gate (`AiConsentController`, `users.ai_consent_at`) in `UserAuth.on_mount(:ensure_authenticated)`. A test that drives a signed-in LiveView with the app's User-Agent needs a user with `ai_consent_at` set.

### Web layer

- Sessions: Google OAuth via Ueberauth only. `UserAuth` has `mount_current_user`, `ensure_authenticated`, `ensure_admin` (`users.is_admin`). Route groups: `:public` (`/p/:slug`, `/p/:slug/guide`, `/p/:slug/:date`), `:authenticated` (`/onboarding`, `/journal`, `/guide`, `/settings`), `:admin` (`/admin`, `/admin/change-stream`).
- Owner and public views share state and markup on purpose: `GuideState` + `GuideComponents` back both `/guide` and `/p/:slug/guide`; `NotebookComponents` renders entries on the owner journal, public journal, and home page. Change these shared modules rather than forking markup.
- `JournalLive` owns the chat sidebar, uploads, the sprite hold while the reader is active (a `SpriteHold` task refreshed each minute, released on quiet or terminate), and the provisioning/setting-up state machine. That is why the guide is a separate LiveView.
- `PushNotifications` and `TelegramPairing` are the server halves of two opt-in flows shared by the journal (first-run nudge) and settings (permanent switch): each LiveView assigns their state and routes the `push_*` / `telegram_*` events to them.
- Agent and chat markdown always goes through a sanitizer (`ChatSidebarComponent.render_markdown/1`, `raw_markdown/3`). Do not render model output with `raw/1` anywhere else.
- `/webhooks/*` uses `Plugs.CacheBodyReader` so Stripe signatures can be checked over the raw body.
- Layout: the notebook's two-page spread is a container query on `.journal-column` with two thresholds (34rem compact, 48rem roomy), not a viewport query. The chat docks beside it only from `xl`; from `md` it is a drawer with a scrim, below that a full-screen overlay; only the docked layout uses a fixed-height desk. Touch rules live under `@media (pointer: coarse)` and safe-area insets on `body`, so none of it needs the app.
- JS hooks live in `assets/js/*_hook.js` and are registered in `app.js`; Leaflet is vendored under `assets/vendor/leaflet` and every map hook (`PoetMap`, `JourneyTour`) imports it through `leaflet_setup.js`, which carries the marker-icon fix. Place links inside sanitized prose lose their `data-phx-link` attributes, so `app.js` patches those clicks itself.

## Testing conventions

- SQLite + `Ecto.Adapters.SQL.Sandbox`. Most cases are `async: false`; only pure-function tests use `async: true`.
- Fixtures in `test/support/fixtures.ex`: `user_fixture` (pass `credits: n`), `agent_user_fixture` (provisioned user with API token), `poet_fixture`, `entry_fixture`, `published_entry_fixture`, `place_fixture`, `media_fixture`.
- Sprite calls in test: swap in `TravelingPoet.SpritesClientRecorder` via the `:sprites_client` app env (see its moduledoc); it forwards every `exec/3` as a message to the test pid and replies `{:ok, ""}`. Clean up in `on_exit`.
- Timers are off in test; tests drive one pass directly: `ChangeStream.Capture.tick/1`, `ChangeStream.Delivery.deliver_pending/1`, `ChangeStream.Worker.check_now/0`, `FleetHealth.Alerter.check_now/0`, `DailyJourneyScheduler.run_now/1`.

## Product and workflow rules

- Work on a branch and open a PR; no direct pushes to `main`.
- UI copy: no em dashes in interface text, no emoji. The wordmark is "Traveling *Poet*" (Poet italic).
- Illustrations must cite real source links; the agent-facing rules in `priv/data/AGENTS.md` are part of the product's safety posture. Do not loosen them without asking.
- Anything under `priv/data/` (skills, AGENTS.md, plugin source in `Provisioner`) reaches a poet only through `Provisioner.upgrade_fleet/1` after deploy. A PR that changes skill text should say so in its description; app-side rules, context fields and CSS need no rollout.
- Commit messages in this repo explain the observed problem first (what the fleet actually did), then the change. Keep that shape.
