---
name: bastion
description: "Manage Bastion AI Gateway — a local security proxy for LLM requests. Start/stop the gateway, view DLP findings, tool guard alerts, usage stats, and configure security policies. Use when a user asks about AI request security, DLP scanning, tool call monitoring, or wants to route LLM traffic through a security gateway."
metadata: {
  "openclaw": {
    "emoji": "🛡️",
    "requires": { "bins": ["node"] },
    "install": [
      {
        "kind": "node",
        "package": "@aion0/bastion",
        "bins": [],
        "label": "Install Bastion AI Gateway"
      }
    ]
  }
}
user-invocable: true
---

# Bastion AI Gateway

Bastion is a local-first HTTPS proxy between AI tools and LLM providers (Anthropic, OpenAI, Gemini). It provides DLP scanning, tool call monitoring, audit logging, and usage metrics with zero cloud dependency.

## Prerequisites — OpenClaw Tool Permissions

This skill requires `exec` and `read` tools to function. If your OpenClaw agent cannot execute commands, add `alsoAllow` to the **correct** config file.

**Config file location**: The Docker container mounts `$OPENCLAW_CONFIG_DIR` (check `.env`). Typically `~/.openclaw/openclaw.json` — **not** `~/openclaw-data/mywork/config/openclaw.json`.

Add `alsoAllow` to the `tools` section:

```json
{
  "tools": {
    "profile": "messaging",
    "alsoAllow": ["exec", "read"]
  }
}
```

After editing, restart OpenClaw (`docker compose restart`) and open a **new chat session**.

## Quick Start

```bash
# Start Bastion on a random port
node skills/bastion/scripts/start.mjs --port 0

# Check if Bastion is running
node skills/bastion/scripts/status.mjs
node skills/bastion/scripts/status.mjs http://127.0.0.1:PORT
```

`start.mjs` outputs a JSON line with `port`, `url`, `authToken`, `dashboardUrl`, `caCertPath`.

## Dashboard

Open `{url}/dashboard` in a browser. API calls require `Authorization: Bearer {authToken}`.

## Connection Info

After Bastion starts, connection details (url, authToken, port, caCertPath) are saved to `~/.bastion/connection.json`. Read this file to get the auth token for API calls:

```bash
cat ~/.bastion/connection.json
```

Use the `authToken` value in API requests: `Authorization: Bearer {authToken}`

## API Endpoints

All under `{url}/api/`:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/stats` | GET | Usage statistics |
| `/api/requests` | GET | Recent requests |
| `/api/dlp-events` | GET | DLP findings |
| `/api/tool-calls` | GET | Tool call records |
| `/api/audit-log` | GET | Audit log entries |
| `/api/config` | GET/PUT | View/update config |

## Routing Traffic Through Bastion

Set these environment variables so LLM clients route through Bastion:

```bash
export HTTPS_PROXY=http://127.0.0.1:{port}
export NODE_EXTRA_CA_CERTS={caCertPath}
```

## Configuration

Runtime config update via API:

```bash
curl -X PUT {url}/api/config \
  -H "Authorization: Bearer {authToken}" \
  -H "Content-Type: application/json" \
  -d '{"plugins":{"dlp":{"action":"redact"}}}'
```

Key settings:
- `plugins.dlp.action`: `pass` | `warn` | `redact` | `block`
- `plugins.toolGuard.action`: `audit` | `block`

## Docker Setup

In Docker (OpenClaw container), Bastion requires a one-time setup after each `docker compose down/up` (not needed after `docker compose restart`).

**Tell the user to run this on the host machine:**

```bash
bash ~/.openclaw/skills/bastion/scripts/docker-setup.sh
```

This installs `@aion0/bastion`, rebuilds native modules, and starts Bastion on port 8420.

If Bastion is not responding (`status.mjs` returns `reachable: false`), remind the user to run the setup script above on the host.

### Why is setup needed after `docker compose down/up`?

`docker compose down` destroys the container and all installed packages. `docker compose restart` preserves the container state, so packages survive. The setup script handles:

1. `pnpm add -w @aion0/bastion` — install in workspace root (not `npm install -g`)
2. Rebuild `better-sqlite3` native module (skipped during pnpm install)
3. Start Bastion on port 8420

### ESM Module Resolution in Docker

Scripts at `~/.openclaw/skills/` run outside `/app/node_modules`, so Node.js ESM cannot resolve `@aion0/bastion` via normal import. `start.mjs` includes a fallback that reads `/app/node_modules/@aion0/bastion/package.json` and uses `pathToFileURL()` for dynamic import.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Agent says "no exec/read tools" | OpenClaw `tools.profile` lacks permissions | Add `"alsoAllow": ["exec", "read"]` to `~/.openclaw/openclaw.json`, restart, new session |
| Config change not taking effect | Edited wrong config file | Check `.env` for `OPENCLAW_CONFIG_DIR` — Docker mounts that path, not `~/openclaw-data/` |
| `Cannot find @aion0/bastion` | Package not installed or container recreated | Run `docker-setup.sh` on host |
| `better-sqlite3` bindings error | Native module not compiled | `docker-setup.sh` handles this; or manually: `cd /app/node_modules/.pnpm/better-sqlite3@*/node_modules/better-sqlite3 && npx --yes prebuild-install` |
| `npm install -g` not found by Node | Global install goes to `/usr/local/lib/`, not `/app/` | Use `pnpm add -w` instead |
| API returns "Unauthorized" | Missing auth token | Read `~/.bastion/connection.json` for `authToken`, use `Authorization: Bearer {token}` |
| Bastion gone after restart | Used `docker compose down/up` instead of `restart` | Re-run `docker-setup.sh`; prefer `docker compose restart` |

## Important Notes

- Always check status before starting to avoid duplicate instances
- Use `--port 0` for random port assignment to avoid conflicts
- Bastion is single-instance per process (singleton database)
- The CA certificate must be trusted by clients using HTTPS proxy mode
