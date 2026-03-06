#!/usr/bin/env bash
# Bastion AI Gateway — Docker setup & upgrade for OpenClaw.
#
# Usage:
#   bash docker-setup.sh                          # first-time setup
#   bash docker-setup.sh upgrade                  # upgrade bastion + skill scripts
#   bash docker-setup.sh [CONTAINER] [PORT] [DIR] # explicit args
#
# Setup (first run):
#   1. Patches docker-compose.yml (env vars, volume, command wrapper)
#   2. Installs @aion0/bastion, rebuilds native deps, verifies health
#
# Upgrade:
#   1. Updates skill scripts from npm (@aion0/bastion-skills)
#   2. Upgrades @aion0/bastion in Docker container
#   3. Restarts bastion process
set -euo pipefail

# ── Detect "upgrade" subcommand ──────────────────────────────────────

ACTION="setup"
if [ "${1:-}" = "upgrade" ]; then
  ACTION="upgrade"
  shift
fi

CONTAINER="${1:-openclaw-openclaw-gateway-1}"
PORT="${2:-8420}"
COMPOSE_DIR="${3:-}"

# ── Locate docker-compose.yml ────────────────────────────────────────

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
  echo "  Pass the directory as arg: bash docker-setup.sh [upgrade] <container> <port> <compose-dir>"
  exit 1
fi

COMPOSE_DIR="$(cd "$(dirname "$COMPOSE_FILE")" && pwd)"

# ── Resolve skill directory ──────────────────────────────────────────

# This script lives in skills/bastion/scripts/ — skill root is two levels up
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Deployed location (where openclaw reads skills from)
DEPLOY_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}/skills/bastion"

# ══════════════════════════════════════════════════════════════════════
# UPGRADE MODE
# ══════════════════════════════════════════════════════════════════════

if [ "$ACTION" = "upgrade" ]; then
  echo "==> Upgrading Bastion skill + package..."

  # ── Step 1: Update skill scripts from npm ──
  echo ""
  echo "==> Updating skill scripts..."
  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT

  # Download latest @aion0/bastion-skills tarball
  npm pack @aion0/bastion-skills --pack-destination "$TMPDIR" 2>/dev/null
  TARBALL=$(ls "$TMPDIR"/aion0-bastion-skills-*.tgz 2>/dev/null | head -1)

  if [ -z "$TARBALL" ]; then
    echo "    WARNING: @aion0/bastion-skills not found on npm, skipping skill update"
  else
    # Extract and copy skill files
    mkdir -p "$TMPDIR/extracted"
    tar xzf "$TARBALL" --strip-components=1 -C "$TMPDIR/extracted"

    if [ -d "$TMPDIR/extracted/skills/bastion" ]; then
      cp -r "$TMPDIR/extracted/skills/bastion/scripts/" "$DEPLOY_DIR/scripts/"
      # Update SKILL.md if present
      [ -f "$TMPDIR/extracted/skills/bastion/SKILL.md" ] && \
        cp "$TMPDIR/extracted/skills/bastion/SKILL.md" "$DEPLOY_DIR/SKILL.md"

      NEW_VER=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMPDIR/extracted/package.json','utf8')).version)" 2>/dev/null || echo "?")
      echo "    Skill scripts updated to v${NEW_VER}"
    else
      echo "    WARNING: skills/bastion not found in tarball, skipping"
    fi
  fi

  # ── Step 2: Upgrade @aion0/bastion in container ──
  echo ""
  echo "==> Upgrading @aion0/bastion in $CONTAINER ..."

  # Stop existing bastion process
  docker exec "$CONTAINER" sh -c 'kill $(cat /home/node/.bastion/bastion.pid 2>/dev/null) 2>/dev/null || true'
  sleep 1

  docker exec --user root -e HTTPS_PROXY= -e HTTP_PROXY= "$CONTAINER" pnpm add -w @aion0/bastion@latest

  # Rebuild native modules
  echo "==> Rebuilding better-sqlite3..."
  docker exec --user root -e HTTPS_PROXY= -e HTTP_PROXY= "$CONTAINER" bash -c \
    'cd /app/node_modules/.pnpm/better-sqlite3@*/node_modules/better-sqlite3 && npx --yes prebuild-install 2>/dev/null || npx --yes node-gyp rebuild 2>/dev/null || true'

  # ── Step 3: Restart bastion ──
  echo ""
  echo "==> Restarting Bastion on port $PORT ..."
  docker exec -d "$CONTAINER" node /home/node/.openclaw/skills/bastion/scripts/start.mjs --port "$PORT"
  sleep 3

  # Health check
  HEALTH=$(docker exec "$CONTAINER" curl -s "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)
  if [ -n "$HEALTH" ]; then
    echo "    Bastion is running: $HEALTH"
  else
    echo "    WARNING: Bastion may still be starting."
  fi

  # Show versions
  echo ""
  PKG_VER=$(docker exec "$CONTAINER" node -e "console.log(JSON.parse(require('fs').readFileSync('/app/node_modules/@aion0/bastion/package.json','utf8')).version)" 2>/dev/null || echo "?")
  echo "==> Upgrade complete!"
  echo "    @aion0/bastion: v${PKG_VER}"
  echo "    Dashboard: http://127.0.0.1:${PORT}/dashboard"
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════
# SETUP MODE (first-time install)
# ══════════════════════════════════════════════════════════════════════

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
    print "        (node /home/node/.openclaw/skills/bastion/scripts/start.mjs --port " PORT " 2>>/home/node/.bastion/bastion.log &"
    print "        sleep 2);"
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
echo "    To upgrade: bash $(basename "$0") upgrade"
