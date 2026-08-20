#!/bin/sh
set -eu

cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "Missing deploy/dendrite/.env. Copy .env.example and set production values." >&2
  exit 1
fi

set -a
. ./.env
set +a

: "${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}"
: "${TURN_SHARED_SECRET:?Set TURN_SHARED_SECRET in .env}"
: "${TURN_HOST:?Set TURN_HOST in .env}"
: "${METRICS_PASSWORD:?Set METRICS_PASSWORD in .env}"

case "$POSTGRES_PASSWORD:$TURN_SHARED_SECRET:$METRICS_PASSWORD" in
  *change_this*)
    echo "Replace every change_this_* value in deploy/dendrite/.env." >&2
    exit 1
    ;;
esac

escape_sed() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

postgres_password=$(escape_sed "$POSTGRES_PASSWORD")
turn_secret=$(escape_sed "$TURN_SHARED_SECRET")
turn_host=$(escape_sed "$TURN_HOST")
metrics_password=$(escape_sed "$METRICS_PASSWORD")

mkdir -p .generated
sed \
  -e "s|change_this_postgres_password|$postgres_password|g" \
  -e "s|change_this_turn_shared_secret|$turn_secret|g" \
  -e "s|change_this_metrics_password|$metrics_password|g" \
  -e "s|turn\.matrix\.wrytte\.com|$turn_host|g" \
  config/dendrite.yaml > .generated/dendrite.yaml

chmod 600 .generated/dendrite.yaml
echo "Generated deploy/dendrite/.generated/dendrite.yaml"
