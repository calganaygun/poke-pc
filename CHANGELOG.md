# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

## [0.1.0] - 2026-03-23

### Added
- Dockerized Poke PC runtime with MCP terminal control over tmux.
- Poke tunnel manager with reconnect loop and adaptive backoff.
- Optional `poke login` bootstrap when API key is not provided.
- Bootstrap command runner from external YAML/JSON config or env list.
- Webhook auto-registration and adaptive long-running/heartbeat/completion notifications.
- Append-only `history.ndjson` command/bootstrap lifecycle audit log.
- Initial OSS release docs and GitHub Actions workflows.
