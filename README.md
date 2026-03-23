<div align="center">
  <h1>Poke PC</h1>
  <img src="header.jpg" alt="Poke PC Header">
  <p>
    safely extend poke's capabilities to your machine with an isolated docker environment
  </p>
  
  <p>
    <img src="https://img.shields.io/badge/Language-JavaScript-yellow" alt="Language">
    <img src="https://img.shields.io/badge/Platform-Docker-blue" alt="Platform">
    <img src="https://img.shields.io/badge/License-MIT-green" alt="License">
    <img src="https://img.shields.io/badge/Version-1.0.1-orange" alt="Version">
  </p>
</div>

```bash
npx poke-pc
```
or
```bash
npx github:calganaygun/poke-pc
```

A Dockerized MCP worker with persistent terminal control, automatic Poke tunnel connection, and optional webhook notifications.

License: MIT

## Introduce Poke PC to your Poke ⭐

Use this direct recipe link:

https://poke.com/r/kWWE0sbthIQ

You can also copy `RECIPE.md` into your Poke configuration.

## Quick Start 🚀

The command runs an interactive setup that:

- checks Docker
- ensures `poke login` credentials exist (required for tunnel)
- asks if webhook mode should be enabled
- asks for `POKE_API_KEY` only if webhook mode is enabled
- creates persistent volume and starts container in detached mode (no `--rm`)

Useful after setup:

```bash
docker logs -f poke-pc
docker exec -it poke-pc tail -f /root/poke-pc/terminal/history.ndjson
```

## Authentication 🔐

- Tunnel auth uses `poke login` credentials from `~/.config/poke/credentials.json`.
- Webhook integration uses `POKE_API_KEY`.
- Get your API key from https://poke.com/kitchen/api-keys.
- Without API key, webhook notifications are disabled.

If credentials are missing on first run, the app shows a login URL and code in logs.

## Manual Docker Run

```bash
docker run -d \
  --name poke-pc \
  -p 3000:3000 \
  -e POKE_TUNNEL_NAME="poke-pc" \
  -e MCP_PUBLIC_URL="http://127.0.0.1:3000/mcp" \
  -e POKE_PC_AUTOREGISTER_WEBHOOK="true" \
  -e POKE_API_KEY="${POKE_API_KEY}" \
  -v poke_pc_state:/root/poke-pc \
  -v "$HOME/.config/poke:/root/.config/poke" \
  ghcr.io/calganaygun/poke-pc:latest
```

To run without webhook integration:

```bash
-e POKE_PC_AUTOREGISTER_WEBHOOK="false"
```

## Configuration

Copy `.env.example` and adjust as needed.

Common defaults:

- `POKE_TUNNEL_NAME=poke-pc`
- `MCP_HOST=0.0.0.0`
- `MCP_PORT=3000`
- `MCP_PUBLIC_URL=http://127.0.0.1:3000/mcp`
- `POKE_PC_AUTOREGISTER_WEBHOOK=false`

Bootstrap config can be loaded from file with `POKE_PC_BOOTSTRAP_CONFIG`.

## MCP Tools

- `terminal_create_session`
- `terminal_list_sessions`
- `terminal_run_command`
- `terminal_get_command_status`
- `terminal_capture_output`
- `terminal_kill_session`
- `terminal_list_commands`

## Project docs

- CONTRIBUTING.md
- CODE_OF_CONDUCT.md
- SECURITY.md
- CHANGELOG.md
- RELEASE_CHECKLIST.md

## Local Development

```bash
npm install
npm run dev
```

## Build

```bash
npm run build
npm start
```

## Runtime behavior

Startup order:

1. Validate config and initialize state directories.
2. Initialize tmux manager and restore known sessions.
3. Run bootstrap commands.
4. Initialize webhook (load persisted or auto-register).
5. Start MCP server.
6. Start Poke tunnel with reconnection loop.
7. Start command monitor for adaptive heartbeat/completion notifications.

## Observability and command history

- Runtime app logs are emitted via pino to container stdout/stderr.
- Command/bootstrap lifecycle events are persisted in append-only NDJSON:
  - `/root/poke-pc/terminal/history.ndjson`
- This history file is intentionally logging-only and not exposed as an MCP tool.

Example:

```bash
docker exec -it poke-pc tail -f /root/poke-pc/terminal/history.ndjson
```

## CI/CD and release

- CI workflow: `.github/workflows/ci.yml`
- GHCR publish workflow: `.github/workflows/docker-publish.yml`
- GitHub release workflow: `.github/workflows/release.yml`

Published image path:

- `ghcr.io/calganaygun/poke-pc`

## Security notes

- Container currently runs as root by design for bootstrap flexibility.
- If using API keys, keep `POKE_API_KEY` in environment secrets, not in image.
- Persisted webhook token is stored in state path with mode `0600`.
- Logs redact common secret fields.
