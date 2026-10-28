# Traveling Poet

The source of [poet.travel](https://poet.travel): each reader gets an AI poet
that travels virtually through real places and writes an illustrated journal
page every day.

It is a Phoenix 1.8 LiveView app on SQLite. Each poet is an OpenClaw agent
running in its own [sprites.dev](https://sprites.dev) sandbox. This app
provisions the agent, drives it, and renders what it writes.

## Architecture

### The app is the driver, the sprite is the writer

```
  reader (browser, home-screen app, iOS app)
        │  LiveView over WebSocket
        ▼
┌───────────────────────────────┐   wake, send a turn    ┌───────────────────────────────┐
│ Phoenix app (one Fly machine) │ ─────────────────────▶ │ sprite (one per poet)         │
│                               │   OpenClaw gateway WS  │                               │
│ schedulers and watchdogs      │                        │ OpenClaw agent                │
│ contexts (Journal, Guide, …)  │                        │ workspace: AGENTS.md, skills/ │
│ SQLite on a volume            │ ◀───────────────────── │ tpoet-plugin (the tool set)   │
│ /api/agent/* (bearer token)   │   tool calls over HTTP │                               │
└───────────────────────────────┘                        └───────────────────────────────┘
        │                                                        │
        │ OpenRouter: drawings, place labels                     │ OpenRouter: the poet's model,
        │ Tigris (S3): media                                     │ web search
        │ Telegram, Web Push, APNs, email: notifications         │
```

- **The poet writes; the app never does.** Every journal page is written on
  the poet's sprite. The app's own model calls only label what a poet already
  wrote (places, topics) and draw the illustrations, so no shared secret ever
  reaches a sprite.
- **The app owns time and counting.** A paused sprite has no clock, so every
  cadence lives in the app: when a poet travels (`DailyJourneyScheduler`),
  when a reader's feedback is passed on (`Markers.Watchdog`), when the poet
  asks the reader something (`Asks.Cadence`). Facts such as the journey day,
  or how many drawings today gets, are computed by the app and handed to the
  agent in `/api/agent/context`.
- **Provisioning.** `Provisioner` creates the sprite, installs OpenClaw, seeds
  the workspace from `priv/data/` (the agent's rules and `skills/*/SKILL.md`),
  installs the `tpoet-plugin` whose tools call back into `/api/agent/*`, and
  pairs a device key. `Provisioner.upgrade_fleet/1` rolls a new workspace out
  to every poet.
- **Driving.** `AgentSession` wakes a sprite, sends a turn, keeps the sprite
  awake while it works (`SpriteHold`), and stores the streamed reply.
  `GatewaySocket` closes itself when idle, because an open socket keeps a
  sprite awake and billing.
- **Rendering is defensive.** Model output is always sanitized before it is
  shown (`NotebookComponents.raw_markdown/3`, the chat's `render_markdown/1`).
  The renderer also lays out media the model forgot to place, without
  touching what is stored.

### Where things live

| Path | What |
|---|---|
| `lib/traveling_poet/` | Contexts: `Journal` (entries, sections, media), `Guide` (places and pins), `Markers` (reader feedback on a page), `Preferences` and `Affinity` (what a reader likes), `Credits`, `Trips`, `Discover`, and the sprite side (`Provisioner`, `AgentSession`, `GatewaySocket`, `SpriteHold`) |
| `lib/traveling_poet_web/` | LiveViews (`live/`), shared components (`components/`), controllers including the agent API (`controllers/api/`), plugs |
| `priv/data/` | What a poet is given: `AGENTS.md`, `skills/*/SKILL.md`, presets, the place topic tree. Read at compile time |
| `priv/gettext/` | UI copy. English and Hebrew are both required |
| `assets/` | Tailwind v4 CSS, JS hooks (`*_hook.js`), vendored Leaflet |
| `test/` | ExUnit tests; fixtures in `test/support/fixtures.ex` |

The app runs on exactly one machine: SQLite on a volume, in-process
schedulers, one Telegram poller. It is not built to scale horizontally.

The iOS app is a thin Capacitor shell around the same site, in its own repo.
Everything it needs from the server is here, and inert in a browser.

**`CLAUDE.md` is the detailed map.** It covers each context, the background
processes and their switches, the PubSub topics, and the iOS integration. It
is written for coding agents and reads just as well for people. `AGENTS.md`
holds the general Phoenix, LiveView, Ecto and Tailwind conventions the code
follows.

## Running it locally

You need Elixir 1.18 and Erlang/OTP 27 (the versions in the `Dockerfile`).

```bash
cp .env.example .env   # no key is required to boot; see below
mix setup              # deps, database, assets
mix phx.server         # http://localhost:4000
```

What works depends on the keys in `.env`:

- **No keys:** the public site and every signed-in page. To sign in without
  Google, create a user in `iex -S mix phx.server`:

  ```elixir
  {:ok, user} =
    TravelingPoet.Accounts.find_or_create_from_oauth(:google, %{
      "sub" => "local-1",
      "email" => "you@example.com",
      "name" => "You"
    })
  ```

  then open `/dev/login/<user.id>`. That route exists only in dev.
- **`GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`:** real sign-in.
- **`SPRITES_TOKEN` and `OPENROUTER_API_KEY`:** a real poet. Onboarding then
  provisions a sprite that writes pages. `PHOENIX_URL` must be reachable from
  the sprite (a tunnel such as ngrok or Tailscale), because the poet's tools
  call back into this app. `mix tpoet.smoke_poet` checks the whole round trip.
- **Tigris (`AWS_*`):** stored drawings. Without it, drawings do not load.
- **Stripe:** leave it blank to get a fake checkout page.

Background jobs stay off until their interval is set (for example
`JOURNEY_CHECK_INTERVAL_MINUTES`). Leave `TELEGRAM_BOT_TOKEN` empty locally
unless the bot is your own: two pollers on one bot token take each other's
messages.

`config/runtime.exs` loads `.env` in every environment, including tests, and
switches every paid or networked service off in `:test`.

## Contributing

Contributions are welcome. For anything larger than a small fix, please open
an issue first so we can agree on the shape before you build it.

### The workflow

1. Fork the repo and branch off `main`. Every change, maintainers' included,
   lands through a pull request.
2. Run `mix precommit` before you push. It compiles with warnings as errors,
   checks for unused deps, formats, checks the translations are up to date,
   and runs the whole suite.
3. Open the PR against `main`. Say what was wrong, what you changed, and how
   you checked it. A screenshot helps for anything visible.

Deploys and fleet rollouts are done by the maintainers after merge.

### Commit messages

Start with the problem as someone saw it, then the change. The subject is a
sentence about the problem:

```
A reader could not tell the poet a drawing was wrong without the marker tray

<what was observed, why it happened, and what this change does about it>
```

### Tests

- Every behaviour change comes with a test that would have failed before it.
- Tests never reach the network. Outbound HTTP uses `Req`, and in tests it
  goes through `Req.Test` stubs; an unstubbed call raises. Calls into a
  sprite go through `TravelingPoet.SpritesClientRecorder`.
- A new external integration needs its key pinned or switched off for `:test`
  in `config/runtime.exs`, or the suite will start spending money.
- Timers are off in tests. Drive one pass directly instead (for example
  `DailyJourneyScheduler.run_now/1`).
- Use the fixtures in `test/support/fixtures.ex`. Most tests touch SQLite and
  run `async: false`; only pure functions run `async: true`.

### UI copy

- Every string a reader sees goes through `gettext` or `dgettext`. After
  adding or changing one, run `mix gettext.extract --merge` and fill in the
  Hebrew in `priv/gettext/he/`. A test fails on a missing translation. Hebrew
  copy avoids gendering the poet.
- No em dashes and no emoji in interface text. The wordmark is
  "Traveling *Poet*", with Poet in italics.

### Changes that need extra care

- **`priv/data/`** (the poet's rules and skills, and the plugin source in
  `Provisioner`) reaches poets only through a fleet rollout after deploy.
  Say in the PR description that it changes skill text. Run
  `mix compile --force` locally to pick up an edit there.
- **The poet's safety rules** in `priv/data/AGENTS.md`, such as citing real
  sources for every drawing and link, are part of the product. Please open an
  issue before loosening any of them.
- **Model output** is rendered only through the sanitizers named above. Never
  render it with `raw/1`.
- **New tables** hanging off `users` must cascade on delete
  (`Accounts.Purge` depends on it), and every new schema must be listed in
  `ChangeStream.Registry`. A test fails otherwise.
- **Shared views:** the owner and public pages share their state and markup
  (`NotebookComponents`, `GuideComponents`). Change the shared module rather
  than forking the markup.

## Security

Please report vulnerabilities privately to support@poet.travel rather than in a
public issue.

## License

GNU Affero General Public License v3.0 (AGPL-3.0); see `LICENSE`.
Contributions are accepted under the same license. If you run a modified
version as a network service, the license requires you to offer its source to
that service's users. The libraries vendored under `assets/vendor` keep their
own licenses.
