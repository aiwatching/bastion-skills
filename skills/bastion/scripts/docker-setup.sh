#!/usr/bin/env bash
# One-click setup for Bastion in OpenClaw Docker container.
#
# Run 1: Patches docker-compose.yml (env vars, volume, command wrapper)
#         → tells user to recreate the container, then exits.
# Run 2: Installs @aion0/bastion, rebuilds native deps, verifies health.
#
# After setup, every `docker compose restart` auto-starts Bastion.
# A `docker compose down/up` loses the package — re-run this script.
#
# Usage: bash docker-setup.sh [CONTAINER_NAME] [PORT] [COMPOSE_DIR]
#
# Examples:
#   bash docker-setup.sh                                              # defaults
#   bash docker-setup.sh openclaw-openclaw-gateway-1 8420 ~/openclaw  # explicit
set -euo pipefail

CONTAINER="${1:-openclaw-openclaw-gateway-1}"
PORT="${2:-8420}"
COMPOSE_DIR="${3:-}"

# ── Locate docker-compose.yml ──────────────────────────────────────

find_compose() {
  if [ -n "$COMPOSE_DIR" ]; then
    echo "$COMPOSE_DIR/docker-compose.yml"
    return
  fi
  for dir in "$HOME/IdeaProjects/openclaw" "$HOME/openclaw" "$(pwd)"; do
    if [ -f "$dir/docker-compose.yml" ]; then
      echo "$dir/docker-compose.yml"
      return
    fi
  done
}

COMPOSE_FILE=$(find_compose)
if [ -z "$COMPOSE_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
  echo "ERROR: docker-compose.yml not found."
  echo "  Pass the directory as 3rd arg: bash docker-setup.sh <container> <port> <compose-dir>"
  exit 1
fi

COMPOSE_DIR="$(cd "$(dirname "$COMPOSE_FILE")" && pwd)"

# ── Phase 0: Ensure Bastion port is exposed ────────────────────────

if ! grep -q "\"${PORT}:${PORT}\"" "$COMPOSE_FILE" 2>/dev/null; then
  echo "==> Exposing port $PORT in $COMPOSE_FILE"
  # macOS sed: -i '' (no backup extension)
  sed -i '' "/OPENCLAW_BRIDGE_PORT/a\\
      - \"${PORT}:${PORT}\"" "$COMPOSE_FILE"
  echo "    Added port mapping ${PORT}:${PORT}"
  COMPOSE_CHANGED=true
else
  echo "==> Port $PORT already exposed"
  COMPOSE_CHANGED=false
fi

# ── Phase 1: Patch compose for Bastion routing ─────────────────────

if ! grep -q "HTTPS_PROXY" "$COMPOSE_FILE"; then
  echo "==> Patching $COMPOSE_FILE for Bastion routing..."
  cp "$COMPOSE_FILE" "${COMPOSE_FILE}.pre-bastion.bak"

  awk -v PORT="$PORT" '
  BEGIN { in_gw=0; in_cmd=0; env_done=0; vol_done=0; cmd_done=0 }

  # Track which service block we are in
  /^  openclaw-gateway:/  { in_gw=1 }
  /^  [a-zA-Z]/ { if ($0 !~ /^  openclaw-gateway:/) in_gw=0 }

  # ── env vars: insert after CLAUDE_WEB_COOKIE (gateway only) ──
  in_gw && /CLAUDE_WEB_COOKIE/ && env_done==0 {
    print
    print "      HTTPS_PROXY: http://127.0.0.1:" PORT
    print "      NODE_EXTRA_CA_CERTS: /home/node/.bastion/ca.crt"
    print "      NO_PROXY: localhost,127.0.0.1,a.claude.ai,claude.ai,console.anthropic.com,platform.claude.com,auth.anthropic.com"
    env_done=1
    next
  }

  # ── volume: insert after workspace mount (gateway only) ──
  in_gw && /OPENCLAW_WORKSPACE_DIR.*workspace/ && vol_done==0 {
    print
    print "      - ${OPENCLAW_CONFIG_DIR}/../.bastion:/home/node/.bastion"
    vol_done=1
    next
  }

  # ── command: replace entire block with Bastion wrapper ──
  in_gw && /^    command:/ && cmd_done==0 {
    in_cmd=1
    print "    command:"
    print "      - sh"
    print "      - -c"
    print "      - >-"
    print "        (node /home/node/.openclaw/skills/bastion/scripts/start.mjs --port " PORT " &"
    print "        sleep 2) 2>/dev/null;"
    print "        exec node dist/index.js gateway --bind ${OPENCLAW_GATEWAY_BIND:-lan} --port 18789"
    cmd_done=1
    next
  }

  # Skip old command block lines until closing bracket
  in_cmd { if (/\]/) in_cmd=0; next }

  # Everything else passes through
  { print }
  ' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"

  echo "    + Added HTTPS_PROXY, NODE_EXTRA_CA_CERTS, NO_PROXY"
  echo "    + Added .bastion volume mount"
  echo "    + Replaced command with Bastion startup wrapper"
  COMPOSE_CHANGED=true
fi

# If we changed the compose file, the container must be recreated.
if [ "$COMPOSE_CHANGED" = true ]; then
  echo ""
  echo "==> docker-compose.yml has been updated."
  echo "    Recreate the container, then re-run this script:"
  echo ""
  echo "    cd $COMPOSE_DIR"
  echo "    docker compose down && docker compose up -d"
  echo "    bash $(realpath "$0") $CONTAINER $PORT $COMPOSE_DIR"
  echo ""
  echo "    (backup saved as docker-compose.yml.pre-bastion.bak)"
  exit 0
fi

echo "==> docker-compose.yml already patched — proceeding to install."

# ── Phase 2: Install @aion0/bastion ────────────────────────────────

echo "==> Installing @aion0/bastion in $CONTAINER ..."
# Bypass HTTPS_PROXY — Bastion isn't running yet during first install
docker exec --user root -e HTTPS_PROXY= -e HTTP_PROXY= "$CONTAINER" pnpm add -w @aion0/bastion

# ── Phase 3: Rebuild native modules ───────────────────────────────

echo "==> Rebuilding better-sqlite3 native module..."
docker exec --user root -e HTTPS_PROXY= -e HTTP_PROXY= "$CONTAINER" bash -c \
  'cd /app/node_modules/.pnpm/better-sqlite3@*/node_modules/better-sqlite3 && npx --yes prebuild-install 2>/dev/null || npx --yes node-gyp rebuild 2>/dev/null || true'

# ── Phase 4: Start Bastion (command wrapper ran before install) ────

echo "==> Starting Bastion on port $PORT ..."
docker exec -d "$CONTAINER" node /home/node/.openclaw/skills/bastion/scripts/start.mjs --port "$PORT"
sleep 3

# ── Phase 5: Health check ─────────────────────────────────────────

echo "==> Health check"
HEALTH=$(docker exec "$CONTAINER" curl -s "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)
if [ -n "$HEALTH" ]; then
  echo "    Bastion is running: $HEALTH"
else
  echo "    WARNING: Bastion may still be starting."
  echo "    Check manually: docker exec $CONTAINER curl -s http://127.0.0.1:${PORT}/health"
fi

# ── Phase 6: Verify proxy routing ─────────────────────────────────

echo ""
echo "==> Verifying proxy configuration..."
PROXY_VAR=$(docker exec "$CONTAINER" sh -c 'echo $HTTPS_PROXY' 2>/dev/null || true)
if [ "$PROXY_VAR" = "http://127.0.0.1:${PORT}" ]; then
  echo "    HTTPS_PROXY = $PROXY_VAR"
else
  echo "    WARNING: HTTPS_PROXY=$PROXY_VAR (expected http://127.0.0.1:${PORT})"
fi

CA_PATH=$(docker exec "$CONTAINER" sh -c 'echo $NODE_EXTRA_CA_CERTS' 2>/dev/null || true)
if [ -n "$CA_PATH" ]; then
  echo "    NODE_EXTRA_CA_CERTS = $CA_PATH"
else
  echo "    WARNING: NODE_EXTRA_CA_CERTS not set"
fi

echo ""
echo "==> Setup complete!"
echo "    Dashboard: http://127.0.0.1:${PORT}/dashboard"
echo "    All LLM traffic from OpenClaw now routes through Bastion."
echo ""
echo "    Next restart will auto-start Bastion."
echo "    After 'docker compose down/up', re-run this script to reinstall."
