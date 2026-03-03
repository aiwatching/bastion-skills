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

## Status

When the Bastion extension is enabled, it starts automatically with the OpenClaw gateway as a background service. Check status:

```bash
node -e "const s = globalThis.__bastionServer; console.log(s ? {port: s.port, url: s.url} : 'not running')"
```

Or use the scripts:

```bash
node skills/bastion/scripts/status.mjs              # default port
node skills/bastion/scripts/status.mjs http://HOST:PORT  # custom
```

## Manual Start (if autoStart is disabled)

```bash
node skills/bastion/scripts/start.mjs --port 0
```

Outputs a JSON line with `port`, `url`, `authToken`, `dashboardUrl`, `caCertPath`.

## Dashboard

Open `{url}/dashboard` in a browser. API calls require `Authorization: Bearer {authToken}`.

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

If `setProxy` is enabled in plugin config, environment variables are set automatically. Otherwise:

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

## Plugin Config (openclaw.json)

```json
{
  "plugins": {
    "entries": {
      "bastion": {
        "enabled": true,
        "config": {
          "autoStart": true,
          "port": 0,
          "silent": true,
          "logLevel": "info",
          "setProxy": false
        }
      }
    }
  }
}
```

## Docker Install

In Docker (OpenClaw container), the auto-installer may use `pnpm add -g` which won't resolve from `/app`. Install to the workspace root instead:

```bash
pnpm add -w @aion0/bastion
```

After installing, rebuild the native module if `better-sqlite3` fails to load:

```bash
cd /app/node_modules/.pnpm/better-sqlite3@*/node_modules/better-sqlite3 && npx --yes prebuild-install || npx --yes node-gyp rebuild
```

Verify:

```bash
node -e "import('@aion0/bastion').then(m => console.log('ok, createServer:', typeof m.createServer))"
```

## Important Notes

- Always check status before manual start to avoid duplicate instances
- Use `port: 0` for random port assignment to avoid conflicts
- Bastion is single-instance per process (singleton database)
- The CA certificate must be trusted by clients using HTTPS proxy mode
