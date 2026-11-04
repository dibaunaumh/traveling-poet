#!/bin/bash
# Deploy traveling-poet to Fly.io. Selects env config and app based on arg.
#
# Usage:
#   ./deploy.sh dev     # deploys to traveling-poet-dev (poet org)
#   ./deploy.sh prod    # deploys to traveling-poet     (once it exists)
#
# Extra args are forwarded to `fly deploy`, e.g. ./deploy.sh dev --ha=false

set -e

ENV="${1:-}"
shift || true

case "$ENV" in
  dev)
    CONFIG="fly.dev.toml"
    APP="traveling-poet-dev"
    ;;
  prod)
    CONFIG="fly.prod.toml"
    APP="traveling-poet"
    ;;
  *)
    echo "Usage: $0 <dev|prod> [extra fly deploy flags]" >&2
    exit 1
    ;;
esac

echo "Deploying to $APP using $CONFIG..."
# The alice_in_context dep lives in a private GitHub repo; hand the builder a token.
BUILD_SECRET=()
if command -v gh >/dev/null 2>&1 && TOKEN="$(gh auth token 2>/dev/null)"; then
  BUILD_SECRET=(--build-secret "GH_TOKEN=$TOKEN")
fi

fly deploy -c "$CONFIG" -a "$APP" "${BUILD_SECRET[@]}" "$@"
