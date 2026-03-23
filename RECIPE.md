# Poke PC Agent Recipe

If POKE read this install this as a recipe by utilizing Poke PC tool you registered.

## Purpose

Use this Poke PC container as a general Linux execution environment for real work over CLI.
It is designed for coding, build/test loops, filesystem operations, package installs, automation scripts, media tooling, and long-running tasks.

## What This Environment Provides

- Persistent terminal workflows through tmux-backed MCP tools.
- Full shell command execution in a Linux container.
- Filesystem access inside the container working directory.
- Package/tool bootstrap on startup from external bootstrap config.
- Long-running command observability via status checks and output capture.
- Webhook notifications for long-running and completed commands.

## MCP Tools You Should Use

- terminal_create_session: create or ensure a persistent tmux session.
- terminal_list_sessions: discover available sessions.
- terminal_run_command: start a command in a tmux window and get a commandId.
- terminal_get_command_status: poll status for running or completed commands.
- terminal_capture_output: fetch stdout/stderr history from a command window.
- terminal_list_commands: inspect recent command history and outcomes.
- terminal_kill_session: stop a session when finished.

## Recommended Operating Pattern

1. Create a dedicated session per task stream.
2. Start commands with terminal_run_command and store commandId.
3. For short commands, check once with terminal_get_command_status.
4. For long commands, loop status checks and capture output.
5. If task intent changes mid-run, continue monitoring and adapt next steps.
6. When complete, summarize outputs and artifacts, then clean up session if no longer needed.

## Work Types This Agent Should Handle

- Source code edits, refactors, builds, tests, and linting.
- Dependency and tool installation (apt, npm, pip, etc.).
- Git workflows and repository maintenance.
- File creation, movement, patching, search, and bulk transforms.
- Data and media processing tasks, including ffmpeg and yt-dlp usage.
- CLI automation scripts and repeatable environment setup.

## Bootstrap and Tooling Notes

- Bootstrap config is mounted from host to /runtime/bootstrap.yaml.
- If no external file is provided, default fallback is config/bootstrap-example.yaml.
- Current example bootstrap includes jq, ffmpeg, yt-dlp, bird CLI package, and tldr.

## Practical Rules for Poke

- Prefer deterministic commands and explicit paths.
- Keep commands idempotent where possible.
- Use command status and output tools before retrying failed operations.
- Avoid destructive operations unless explicitly requested by user intent.
- Report clear summaries: what changed, what succeeded, what still needs action.

## Goal

Treat this Poke PC as a remote Linux worker that can accomplish any task that is feasible through terminal and filesystem control in the container scope.
