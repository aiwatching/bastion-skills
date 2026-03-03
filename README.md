# Bastion AI Gateway — OpenClaw Skill

Local-first security gateway for LLM requests. DLP scanning, tool call monitoring, audit logging.

## Setup

### 1. Install skill

```bash
cp -r skills/bastion ~/.openclaw/skills/bastion
```

### 2. Enable agent permissions

Edit `~/.openclaw/openclaw.json`:

```jsonc
{
  "tools": {
    "profile": "messaging",
    "alsoAllow": ["exec", "read"]  // add this line
  }
}
```

> Check `.env` for `OPENCLAW_CONFIG_DIR` to confirm the correct config path.

### 3. Install Bastion in Docker

Run on host:

```bash
bash ~/.openclaw/skills/bastion/scripts/docker-setup.sh
```

> Re-run after `docker compose down/up`. Not needed after `docker compose restart`.

### 4. Restart & verify

```bash
docker compose restart
```

Open a new chat session, ask the agent to check Bastion status.

## How it works

```
Host                              Docker Container
─────                             ─────────────────
~/.openclaw/ ──mount──>  /home/node/.openclaw/
                                  ├── openclaw.json (config)
                                  └── skills/bastion/scripts/
                                       ├── start.mjs   → launches @aion0/bastion
                                       ├── status.mjs   → health check
                                       └── docker-setup.sh

                                  /home/node/.bastion/
                                       └── connection.json (url, authToken, port)
```

- `docker-setup.sh` installs `@aion0/bastion` via `pnpm add -w` and rebuilds native modules
- `start.mjs` includes an ESM fallback for Docker — scripts at `~/.openclaw/` can't resolve `/app/node_modules` normally, so it uses `pathToFileURL()` for dynamic import
- Auth token is persisted to `~/.bastion/connection.json` so agents can read it for API calls
- Dashboard at `http://127.0.0.1:8420/dashboard`

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Agent says "no exec/read tools" | Add `alsoAllow` (step 2), restart, **new session** |
| Config change not working | Check `.env` `OPENCLAW_CONFIG_DIR` — edit that path's `openclaw.json` |
| `Cannot find @aion0/bastion` | Re-run `docker-setup.sh` (step 3) |
| API returns 401 | Auth token is in `~/.bastion/connection.json` |
| Bastion gone after restart | `down/up` destroys packages — re-run step 3 |

## License

MIT
