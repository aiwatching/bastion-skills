#!/usr/bin/env bash
# One-click setup for Bastion in OpenClaw Docker container.
# Usage: bash docker-setup.sh [CONTAINER_NAME] [PORT] [COMPOSE_DIR]
#
# Examples:
#   bash docker-setup.sh                                              # defaults
#   bash docker-setup.sh openclaw-openclaw-gateway-1 8420 ~/openclaw  # explicit
set -euo pipefail

CONTAINER="${1:-openclaw-openclaw-gateway-1}"
PORT="${2:-8420}"
COMPOSE_DIR="${3:-}"

# --- Step 0: Expose Bastion port in docker-compose.yml ---
expose_port() {
  local compose_file=""

  # Find docker-compose.yml
  if [ -n "$COMPOSE_DIR" ]; then
    compose_file="$COMPOSE_DIR/docker-compose.yml"
  else
    # Search common locations
    for dir in "$HOME/IdeaProjects/openclaw" "$HOME/openclaw" "$(pwd)"; do
      if [ -f "$dir/docker-compose.yml" ]; then
        compose_file="$dir/docker-compose.yml"
        break
      fi
    done
  fi

  if [ -z "$compose_file" ] || [ ! -f "$compose_file" ]; then
    echo "==> docker-compose.yml not found, skipping port exposure"
    echo "    Add '- \"${PORT}:${PORT}\"' to ports manually if needed"
    return 0
  fi

  if grep -q "\"${PORT}:${PORT}\"" "$compose_file" 2>/dev/null; then
    echo "==> Port $PORT already exposed in $compose_file"
  else
    echo "==> Exposing port $PORT in $compose_file"
    # Insert after the last existing port mapping
    sed -i.bak "/OPENCLAW_BRIDGE_PORT/a\\
      - \"${PORT}:${PORT}\"" "$compose_file"
    rm -f "${compose_file}.bak"
    echo "    Added port mapping ${PORT}:${PORT}"
    echo "    Run: cd $(dirname "$compose_file") && docker compose down && docker compose up -d"
    echo "    Then re-run this script."
    exit 0
  fi
}

expose_port

# --- Step 1: Install @aion0/bastion ---
echo "==> Installing @aion0/bastion in $CONTAINER"
docker exec --user root "$CONTAINER" pnpm add -w @aion0/bastion

# --- Step 2: Rebuild native modules ---
echo "==> Rebuilding better-sqlite3 native module"
docker exec --user root "$CONTAINER" bash -c \
  'cd /app/node_modules/.pnpm/better-sqlite3@*/node_modules/better-sqlite3 && npx --yes prebuild-install 2>/dev/null || npx --yes node-gyp rebuild 2>/dev/null || true'

# --- Step 3: Start Bastion ---
echo "==> Starting Bastion on port $PORT"
docker exec -d "$CONTAINER" node /home/node/.openclaw/skills/bastion/scripts/start.mjs --port "$PORT"

# Wait a moment for startup
sleep 2

# --- Step 4: Health check ---
echo "==> Health check"
HEALTH=$(docker exec "$CONTAINER" curl -s "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)
if [ -n "$HEALTH" ]; then
  echo "Bastion is running: $HEALTH"
  echo "Dashboard: http://127.0.0.1:${PORT}/dashboard"
else
  echo "WARNING: Health check returned empty. Check logs:"
  echo "  docker exec $CONTAINER node /home/node/.openclaw/skills/bastion/scripts/start.mjs --port $PORT"
fi
