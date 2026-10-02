# Traveling Poet

The source of [poet.travel](https://poet.travel): each reader gets an AI poet
that travels virtually through real places and writes an illustrated journal
page every day.

A Phoenix LiveView app on SQLite. Each poet is an OpenClaw agent in its own
sprites.dev sandbox; this app provisions it, drives it, and renders what it
writes. `CLAUDE.md` describes the architecture.

## Running it locally

```bash
cp .env.example .env   # then fill in the keys you need
mix setup
mix phx.server         # http://localhost:4000
```

`mix precommit` compiles with warnings as errors, formats, and runs the tests.

## Security

Please report vulnerabilities privately to support@poet.travel rather than in a
public issue.

## License

GNU Affero General Public License v3.0 (AGPL-3.0); see `LICENSE`. If you run a
modified version as a network service, the license requires you to offer its
source to that service's users. The libraries vendored under `assets/vendor`
keep their own licenses.
