# Poke PC

Poke PC is a Dockerized MCP worker that exposes persistent tmux-powered terminal control over MCP, connects itself to Poke using a managed tunnel, and sends adaptive webhook notifications for long-running command progress and completion.

License: MIT (see LICENSE).

## Poke agent recipe
You can use prepared recipe from me by using [this link](https://poke.com/r/kWWE0sbthIQ) or copy the content of RECIPE.md and use it as a recipe in your Poke agent configuration.

Use RECIPE.md as the operational playbook for how Poke should use this container for full CLI and filesystem workflows.

## Project docs

- CONTRIBUTING.md
- CODE_OF_CONDUCT.md
- SECURITY.md
- CHANGELOG.md
- RELEASE_CHECKLIST.md

## Features

- Typed Node.js + TypeScript runtime with strict compiler settings.
- MCP server endpoint at `/mcp` with terminal tools.
- Persistent tmux session orchestration with restart reconciliation.
- Pre-start bootstrap installs from config file or env command list.
- Poke tunnel auto-connect using API key or login credentials from poke CLI.
- Webhook auto-registration and adaptive pinging:
  - Completion ping for every command.
  - Long-running transition ping when threshold is crossed.
  - Heartbeat pings at configured interval while still running.

## MCP tools

- `terminal_create_session`
- `terminal_list_sessions`
- `terminal_run_command`
- `terminal_get_command_status`
- `terminal_capture_output`
- `terminal_kill_session`
- `terminal_list_commands`

## Environment variables

Copy `.env.example` and adjust only what you need.

Default tunnel name:

- `POKE_TUNNEL_NAME=poke-pc`

Authentication options:

- Option A: set `POKE_API_KEY` (required for webhook integration)
- Option B: run `poke login` (required for tunnel to poke)

Tunnel auth precedence:

- Tunnel uses `poke login` credentials from `~/.config/poke/credentials.json` only.
- `POKE_API_KEY` is not used for tunnel authentication.
- If credentials are missing, startup triggers device login and stores credentials.

Webhook rule:

- Webhook integration requires `POKE_API_KEY`.
- If `POKE_API_KEY` is not set, webhook notifications are disabled.
- If `POKE_PC_AUTOREGISTER_WEBHOOK=true`, `POKE_API_KEY` is required.

First connection behavior without API key:

- If host credentials exist and are mounted (`${HOME}/.config/poke` -> `/root/.config/poke`), Poke PC uses them immediately.
- If no mounted credentials are found on first run, the container automatically starts `poke login`.
- It logs a device `userCode` and `loginUrl`; open the URL and complete login once.
- Credentials are then saved in the container and reused on next starts.

Useful defaults:

- `POKE_TUNNEL_NAME=poke-pc`
- `MCP_HOST=0.0.0.0`
- `MCP_PORT=3000`
- `MCP_PUBLIC_URL=http://127.0.0.1:3000/mcp`
- `POKE_PC_AUTOREGISTER_WEBHOOK=false`

## Bootstrap configuration

Provide file via `POKE_PC_BOOTSTRAP_CONFIG` (JSON or YAML), example:

```yaml
strict: true
commands:
  - apt-get update && apt-get install -y jq
  - npm install -g tldr
```

Fallback path: use `POKE_PC_BOOTSTRAP_COMMANDS` as newline-delimited command list.

Note: this image currently runs as root at runtime so bootstrap can perform apt operations inside the container. Core system tools (tmux, jq, ffmpeg, python3/pip, curl, build-essential) are also baked into the image for faster startup.

## Local development

```bash
npm install
npm run dev
```

## Build

```bash
npm run build
npm start
```

## Docker

```bash
docker compose up --build
```

Run directly from published image:

**⚠️ WARNING:** Ensure you have `POKE_API_KEY` set in your environment for webhooks, and you ran `poke login` at least once for tunnel credentials.

```bash
docker run --rm -it \
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

First run note (no host credentials):

- If `$HOME/.config/poke/credentials.json` does not exist, container logs will print a login URL and user code.
- Open the URL in a browser and finish login once.
- The mounted config path keeps credentials for future runs.

If you see API key permission errors during webhook setup:

- Webhook mode requires `POKE_API_KEY` and appropriate webhook scopes.
- If scope is missing, webhook registration is skipped and notifications are not sent.
- To run without webhook integration, set `POKE_PC_AUTOREGISTER_WEBHOOK=false`.

Compose bootstrap behavior:

- Bootstrap config is always loaded from a host-mounted external file at `/runtime/bootstrap.yaml`.
- Set `POKE_PC_BOOTSTRAP_FILE` to any host file path you want to use.
- If `POKE_PC_BOOTSTRAP_FILE` is not set, compose falls back to `./config/bootstrap-example.yaml`.
- Compose also mounts `${HOME}/.config/poke` to `/root/.config/poke` so login credentials can be used automatically.

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
