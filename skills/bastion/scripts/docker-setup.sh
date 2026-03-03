#!/usr/bin/env bash
# One-click setup for Bastion in OpenClaw Docker container.
# Usage: bash docker-setup.sh [CONTAINER_NAME] [PORT]
#
# Examples:
#   bash docker-setup.sh                                    # defaults
#   bash docker-setup.sh openclaw-openclaw-gateway-1 8420   # explicit
set -euo pipefail

CONTAINER="${1:-openclaw-openclaw-gateway-1}"
PORT="${2:-8420}"

echo "==> Installing @aion0/bastion in $CONTAINER"
docker exec --user root "$CONTAINER" pnpm add -w @aion0/bastion

echo "==> Rebuilding better-sqlite3 native module"
docker exec --user root "$CONTAINER" bash -c \
  'cd /app/node_modules/.pnpm/better-sqlite3@*/node_modules/better-sqlite3 && npx --yes prebuild-install 2>/dev/null || npx --yes node-gyp rebuild 2>/dev/null || true'

echo "==> Starting Bastion on port $PORT"
docker exec -d "$CONTAINER" node /home/node/.openclaw/skills/bastion/scripts/start.mjs --port "$PORT"

# Wait a moment for startup
sleep 2

echo "==> Health check"
HEALTH=$(docker exec "$CONTAINER" curl -s "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)
if [ -n "$HEALTH" ]; then
  echo "Bastion is running: $HEALTH"
else
  echo "WARNING: Health check returned empty. Check logs:"
  echo "  docker exec $CONTAINER node /home/node/.openclaw/skills/bastion/scripts/start.mjs --port $PORT"
fi
