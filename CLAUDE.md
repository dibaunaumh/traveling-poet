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
```

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
- Model policy: one OpenRouter key for the whole fleet. `OPENROUTER_MODEL` is the default, `SCOUT_MODEL` overrides for scout-mode poets, `IMAGE_GEN_MODEL` for illustrations, `EXTRACTION_MODEL` only for the places backfill. Test env pins distinct fake slugs so policy tests are real assertions.

## Architecture

### The app is the driver, the sprite is the writer

The Phoenix app never writes journal prose itself. The only server-side text LLM call is `Guide.Extractor` (backfill only). Everything else the poet writes happens on its sprite.

- `Provisioner` creates the sprite, installs OpenClaw, writes `~/.openclaw/openclaw.json` and `.env`, seeds the workspace from `priv/data/` (AGENTS.md, BOOTSTRAP.md, HEARTBEAT.md, `skills/*/SKILL.md`), generates and installs the `tpoet-plugin` (the agent's tool set, source in `Provisioner.tpoet_plugin_source/2`), starts the gateway, and pairs an Ed25519 device. Idempotent. `Provisioner.upgrade_workspace/1` re-seeds workspace + plugin for one poet; `Provisioner.upgrade_fleet/1` rolls that across every provisioned poet, staggered.
- `priv/data/**` is read at compile time; editing a SKILL.md or `poet_presets.json` needs `mix compile --force` before the change is picked up.
- The plugin's tools call back into `/api/agent/*` (bearer token = `users.agent_api_token`, shape `<user_id>.<secret>`, verified by `Plugs.AgentAuth`). Tool handlers must have arity `(toolCallId, params)`; `agent_plugin_test.exs` pins this because a one-arg handler silently receives the call id as its body.
- `GatewaySocket` (WebSockex, `restart: :temporary`) is the WebSocket client into a sprite's OpenClaw gateway. It is started on demand via `GatewaySocketSupervisor.ensure_connected/1` and closes itself when idle, because an open socket keeps the sprite awake and billing. Never make it permanent.
- `AgentSession` is the headless exchange (wake sprite, send, hold awake, collect streamed reply, persist to `Chat`) used by everything that talks to a poet without a browser: the daily scheduler, first-entry kickoff, Telegram relay.

### Background processes (all in `Application`, all no-op unless configured)

| Process | Env switch | Purpose |
|---|---|---|
| `DailyJourneyScheduler` | `JOURNEY_CHECK_INTERVAL_MINUTES` | Fires `/travel-and-journal` at due poets; a run counts only if the poet actually published; max 3 attempts/day |
| `FirstEntry.Watchdog` | `FIRST_ENTRY_CHECK_INTERVAL_MINUTES` (default 5) | Retries `/onboard` until the first entry is published |
| `Markers.Watchdog` | `MARKER_DELIVERY_INTERVAL_MINUTES` (+ `MARKER_QUIET_MINUTES`, default 15) | Sends the reader's feedback markers to the poet as one `/revise-entry` turn once the reader has been quiet |
| `FleetHealth.Alerter` | `FLEET_HEALTH_CHECK_INTERVAL_MINUTES` | Pages admins over Telegram about poets that stopped publishing |
| `ChangeStream.Worker` | `CHANGE_STREAM_POLL_SECONDS` + a registered endpoint | Snapshot-diff outbox + signed webhook delivery for external agents |
| `Telegram.Poller` / `Telegram.Notifier` | `TELEGRAM_BOT_TOKEN` | Pairing, chat relay, publish notes |
| `WebPush.Notifier` | VAPID keys | Browser push on publish |
| `Geocoder.Limiter` | always on | Serialises every Nominatim call to 1 req/s app-wide. All geocoding must go through it |

The app runs on exactly ONE Fly machine (SQLite on a volume, single Telegram poller, in-process schedulers). Never scale horizontally, and never set `min_machines_running` to 0.

### PubSub topics

- `"user:#{user_id}"`: `{:sprite_provisioned, ...}`, credit changes, Telegram pairing.
- `"poet:#{poet_id}"`: `{:journal_published, entry_id}`, geocoding results; subscribed by owner and public journal/guide LiveViews.
- `"journal:published"`: `{:journal_published, poet_id, entry_id}` for cross-cutting listeners (notifiers, landing map).
- `"credits:low"`.

### Contexts worth knowing before touching them

- `Journal` (entries, typed sections, media, reactions) vs `Guide` (places with geocoded pins and poet ratings). Keep places OUT of `journal_sections`: `replace_sections/2` wipes and re-inserts on every agent re-put and would destroy coordinates and drawings.
- `Preferences` learns what the companion wants from taps, chat, reactions and settings, with decay and sticky dismissal. The agent may only ADD preferences (source forced to `"chat"`), never delete. `Preferences.Cadence` decides when to ask; the app owns that decision, not the model.
- `Credits` is an append-only ledger in milli-credits; flat rate per daily run by mission (`wander`, `scout`). `Usage` holds the daily abuse caps. `quota_exempt` users are free.
- `Illustrations` generates images server-side via OpenRouter so no shared secret reaches the sprite; media lives in Tigris (S3) via `Storage.S3`, served through `/media/:id` which authorizes on `poet.is_public`.
- `ChangeStream.Registry` must list every Ecto schema as streamed or excluded; `registry_test.exs` fails the build otherwise. `Serializer` redacts by field name (anything token/secret/key-like, emails, chat content) and OMITS the key rather than masking it.
- `Accounts.Purge` relies on `on_delete: :delete_all` everywhere and `PRAGMA foreign_keys` being on. New tables hanging off `users` must cascade.

### Web layer

- Sessions: Google OAuth via Ueberauth only. `UserAuth` has `mount_current_user`, `ensure_authenticated`, `ensure_admin` (`users.is_admin`). Route groups: `:public` (`/p/:slug`, `/p/:slug/guide`, `/p/:slug/:date`), `:authenticated` (`/onboarding`, `/journal`, `/guide`, `/settings`), `:admin` (`/admin`, `/admin/change-stream`).
- Owner and public views share state and markup on purpose: `GuideState` + `GuideComponents` back both `/guide` and `/p/:slug/guide`; `NotebookComponents` renders entries on the owner journal, public journal, and home page. Change these shared modules rather than forking markup.
- `JournalLive` owns the chat sidebar, uploads, sprite keepalive timers, and the provisioning/setting-up state machine. That is why the guide is a separate LiveView.
- `/webhooks/*` uses `Plugs.CacheBodyReader` so Stripe signatures can be checked over the raw body.
- JS hooks live in `assets/js/*_hook.js` and are registered in `app.js`; Leaflet is vendored under `assets/vendor/leaflet`.

## Testing conventions

- SQLite + `Ecto.Adapters.SQL.Sandbox`. Most cases are `async: false`; only pure-function tests use `async: true`.
- Fixtures in `test/support/fixtures.ex`: `user_fixture` (pass `credits: n`), `agent_user_fixture` (provisioned user with API token), `poet_fixture`, `entry_fixture`, `published_entry_fixture`, `place_fixture`, `media_fixture`.
- Timers are off in test; tests drive one pass directly: `ChangeStream.Capture.tick/1`, `ChangeStream.Delivery.deliver_pending/1`, `ChangeStream.Worker.check_now/0`, `FleetHealth.Alerter.check_now/0`, `DailyJourneyScheduler.run_now/1`.

## Product and workflow rules

- Work on a branch and open a PR; no direct pushes to `main`.
- UI copy: no em dashes in interface text, no emoji. The wordmark is "Traveling *Poet*" (Poet italic).
- Illustrations must cite real source links; the agent-facing rules in `priv/data/AGENTS.md` are part of the product's safety posture. Do not loosen them without asking.
