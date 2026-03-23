import { randomUUID } from "node:crypto";
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { spawn } from "node:child_process";
import { z } from "zod";
import type { Logger } from "pino";

export type CommandStatus = "running" | "completed" | "failed" | "lost";

const CONTROL_SESSION_NAME = "__poke_pc_control__";

export type CommandRecord = {
  id: string;
  sessionName: string;
  windowName: string;
  command: string;
  startedAt: string;
  endedAt: string | undefined;
  exitCode: number | undefined;
  status: CommandStatus;
  longRunningNotified: boolean;
  completionNotified: boolean;
  lastHeartbeatAt: string | undefined;
};

type TerminalState = {
  sessions: string[];
  commands: CommandRecord[];
};

const stateSchema = z.object({
  sessions: z.array(z.string()).default([]),
  commands: z
    .array(
      z.object({
        id: z.string(),
        sessionName: z.string(),
        windowName: z.string(),
        command: z.string(),
        startedAt: z.string(),
        endedAt: z.string().optional(),
        exitCode: z.number().int().optional(),
        status: z.enum(["running", "completed", "failed", "lost"]),
        longRunningNotified: z.boolean().default(false),
        completionNotified: z.boolean().default(false),
        lastHeartbeatAt: z.string().optional()
      })
    )
    .default([])
});

export class TerminalManager {
  private readonly statePath: string;
  private readonly historyPath: string;
  private readonly logger: Logger;
  private state: TerminalState;

  public constructor(statePath: string, logger: Logger) {
    this.statePath = statePath;
    this.historyPath = `${dirname(statePath)}/history.ndjson`;
    this.logger = logger.child({ component: "terminal" });
    this.state = this.loadState();
  }

  public async init(restoreSessions: boolean): Promise<void> {
    this.logger.info({ restoreSessions }, "Initializing terminal manager.");
    await this.ensureTmuxAvailable();
    await this.ensureTmuxServerReady();
    await this.runTmux(["set-option", "-g", "remain-on-exit", "on"]);
    await this.runTmux(["set-option", "-g", "history-limit", "50000"]);

    if (restoreSessions) {
      await this.restoreSessions();
    }

    await this.refreshAllCommandStatuses();
    this.logger.info(
      {
        sessionCount: this.state.sessions.length,
        commandCount: this.state.commands.length
      },
      "Terminal manager initialized."
    );
  }

  public listSessionsFromState(): string[] {
    return [...this.state.sessions];
  }

  public async listActiveTmuxSessions(): Promise<string[]> {
    const result = await this.runTmux(["list-sessions", "-F", "#{session_name}"], true);
    if (result.exitCode !== 0 || result.stdout.trim().length === 0) {
      return [];
    }

    return result.stdout
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.length > 0)
      .filter((line) => line !== CONTROL_SESSION_NAME);
  }

  public async ensureSession(sessionName: string): Promise<void> {
    const check = await this.runTmux(["has-session", "-t", sessionName], true);
    if (check.exitCode !== 0) {
      await this.runTmux(["new-session", "-d", "-s", sessionName]);
      this.logger.info({ sessionName }, "Created tmux session.");
    }

    if (!this.state.sessions.includes(sessionName)) {
      this.state.sessions.push(sessionName);
      this.saveState();
    }
  }

  public async killSession(sessionName: string): Promise<void> {
    if (sessionName === CONTROL_SESSION_NAME) {
      throw new Error("Cannot kill internal control session");
    }

    await this.runTmux(["kill-session", "-t", sessionName]);
    this.logger.info({ sessionName }, "Killed tmux session.");
    this.state.sessions = this.state.sessions.filter((name) => name !== sessionName);
    this.appendHistory("session_killed", { sessionName });

    for (const command of this.state.commands) {
      if (command.sessionName === sessionName && command.status === "running") {
        command.status = "lost";
        command.endedAt = new Date().toISOString();
        this.appendHistory("command_lost", {
          commandId: command.id,
          sessionName: command.sessionName,
          windowName: command.windowName,
          command: command.command,
          endedAt: command.endedAt
        });
      }
    }

    this.saveState();
  }

  public async runCommand(sessionName: string, command: string): Promise<CommandRecord> {
    await this.ensureSession(sessionName);

    const commandId = randomUUID();
    const windowName = `cmd-${commandId.slice(0, 8)}`;
    const shellCommand = `bash -lc ${singleQuote(command)}`;

    await this.runTmux([
      "new-window",
      "-d",
      "-t",
      sessionName,
      "-n",
      windowName,
      shellCommand
    ]);

    const record: CommandRecord = {
      id: commandId,
      sessionName,
      windowName,
      command,
      startedAt: new Date().toISOString(),
      endedAt: undefined,
      exitCode: undefined,
      status: "running",
      longRunningNotified: false,
      completionNotified: false,
      lastHeartbeatAt: undefined
    };

    this.state.commands.push(record);
    this.saveState();
    this.logger.info({ commandId, sessionName, windowName }, "Command started.");
    this.appendHistory("command_started", {
      commandId: record.id,
      sessionName: record.sessionName,
      windowName: record.windowName,
      command: record.command,
      startedAt: record.startedAt
    });

    return record;
  }

  public getCommandById(commandId: string): CommandRecord | undefined {
    return this.state.commands.find((command) => command.id === commandId);
  }

  public listCommands(limit = 50): CommandRecord[] {
    return [...this.state.commands]
      .sort((a, b) => b.startedAt.localeCompare(a.startedAt))
      .slice(0, limit);
  }

  public getRunningCommands(): CommandRecord[] {
    return this.state.commands.filter((command) => command.status === "running");
  }

  public markLongRunningNotified(commandId: string, heartbeatAt?: Date): void {
    const command = this.getCommandById(commandId);
    if (!command) {
      return;
    }

    command.longRunningNotified = true;
    if (heartbeatAt) {
      command.lastHeartbeatAt = heartbeatAt.toISOString();
    }
    this.saveState();
  }

  public markHeartbeat(commandId: string, heartbeatAt: Date): void {
    const command = this.getCommandById(commandId);
    if (!command) {
      return;
    }

    command.lastHeartbeatAt = heartbeatAt.toISOString();
    this.saveState();
  }

  public markCompletionNotified(commandId: string): void {
    const command = this.getCommandById(commandId);
    if (!command) {
      return;
    }

    command.completionNotified = true;
    this.saveState();
  }

  public async refreshAllCommandStatuses(): Promise<CommandRecord[]> {
    const changed: CommandRecord[] = [];

    for (const command of this.state.commands) {
      if (command.status !== "running") {
        continue;
      }

      const before = command.status;
      await this.refreshCommandStatus(command);
      if (command.status !== before) {
        changed.push(command);
        this.logger.info(
          {
            commandId: command.id,
            status: command.status,
            exitCode: command.exitCode
          },
          "Command status changed."
        );
        this.appendHistory("command_status_changed", {
          commandId: command.id,
          sessionName: command.sessionName,
          windowName: command.windowName,
          command: command.command,
          status: command.status,
          exitCode: command.exitCode,
          endedAt: command.endedAt
        });
      }
    }

    if (changed.length > 0) {
      this.saveState();
    }

    return changed;
  }

  public async captureOutput(commandId: string, lines = 200): Promise<string> {
    const command = this.getCommandById(commandId);
    if (!command) {
      throw new Error(`Command not found: ${commandId}`);
    }

    const target = `${command.sessionName}:${command.windowName}`;
    const result = await this.runTmux([
      "capture-pane",
      "-p",
      "-t",
      target,
      "-S",
      `-${Math.max(1, lines).toString()}`
    ], true);

    if (result.exitCode !== 0) {
      return "";
    }

    return result.stdout;
  }

  private async refreshCommandStatus(command: CommandRecord): Promise<void> {
    const target = `${command.sessionName}:${command.windowName}`;
    const probe = await this.runTmux([
      "list-panes",
      "-t",
      target,
      "-F",
      "#{pane_dead} #{pane_dead_status}"
    ], true);

    if (probe.exitCode !== 0) {
      command.status = "lost";
      command.endedAt = command.endedAt ?? new Date().toISOString();
      this.logger.warn({ commandId: command.id }, "Command window no longer exists.");
      return;
    }

    const firstLine = probe.stdout.split("\n").find((line) => line.trim().length > 0);
    if (!firstLine) {
      return;
    }

    const [paneDeadRaw, paneStatusRaw] = firstLine.trim().split(/\s+/);
    const paneDead = paneDeadRaw === "1";
    if (!paneDead) {
      return;
    }

    const exitCode = Number.parseInt(paneStatusRaw ?? "1", 10);
    command.exitCode = Number.isNaN(exitCode) ? 1 : exitCode;
    command.status = command.exitCode === 0 ? "completed" : "failed";
    command.endedAt = command.endedAt ?? new Date().toISOString();
  }

  private async restoreSessions(): Promise<void> {
    for (const sessionName of this.state.sessions) {
      await this.ensureSession(sessionName);
      this.appendHistory("session_restored", { sessionName });
    }

    if (this.state.sessions.length > 0) {
      this.logger.info({ count: this.state.sessions.length }, "Restored persisted tmux sessions.");
    }
  }

  private async ensureTmuxServerReady(): Promise<void> {
    const hasSession = await this.runTmux(["has-session", "-t", CONTROL_SESSION_NAME], true);
    if (hasSession.exitCode !== 0) {
      await this.runTmux(["new-session", "-d", "-s", CONTROL_SESSION_NAME]);
    }
  }

  private loadState(): TerminalState {
    mkdirSync(dirname(this.statePath), { recursive: true });

    try {
      const raw = readFileSync(this.statePath, "utf8");
      const parsed = stateSchema.parse(JSON.parse(raw));
      return {
        sessions: parsed.sessions,
        commands: parsed.commands.map((item) => ({
          id: item.id,
          sessionName: item.sessionName,
          windowName: item.windowName,
          command: item.command,
          startedAt: item.startedAt,
          endedAt: item.endedAt,
          exitCode: item.exitCode,
          status: item.status,
          longRunningNotified: item.longRunningNotified,
          completionNotified: item.completionNotified,
          lastHeartbeatAt: item.lastHeartbeatAt
        }))
      };
    } catch {
      const emptyState: TerminalState = { sessions: [], commands: [] };
      writeFileSync(this.statePath, JSON.stringify(emptyState, null, 2));
      return emptyState;
    }
  }

  private saveState(): void {
    writeFileSync(this.statePath, JSON.stringify(this.state, null, 2));
  }

  private appendHistory(type: string, data: Record<string, unknown>): void {
    const entry = {
      timestamp: new Date().toISOString(),
      type,
      ...data
    };

    appendFileSync(this.historyPath, `${JSON.stringify(entry)}\n`);
  }

  private async ensureTmuxAvailable(): Promise<void> {
    const result = await this.runTmux(["-V"], true);
    if (result.exitCode !== 0) {
      throw new Error("tmux is required but not available in PATH");
    }
  }

  private runTmux(
    args: string[],
    allowFailure = false
  ): Promise<{ stdout: string; stderr: string; exitCode: number }> {
    return new Promise((resolve, reject) => {
      const child = spawn("tmux", args, {
        stdio: ["ignore", "pipe", "pipe"],
        env: process.env
      });

      let stdout = "";
      let stderr = "";

      child.stdout.on("data", (chunk) => {
        stdout += String(chunk);
      });

      child.stderr.on("data", (chunk) => {
        stderr += String(chunk);
      });

      child.on("error", (error) => {
        reject(error);
      });

      child.on("close", (code) => {
        const exitCode = code ?? 1;
        if (!allowFailure && exitCode !== 0) {
          reject(new Error(`tmux ${args.join(" ")} failed: ${stderr.trim() || stdout.trim()}`));
          return;
        }

        resolve({ stdout, stderr, exitCode });
      });
    });
  }
}

function singleQuote(command: string): string {
  return `'${command.replaceAll("'", `'"'"'`)}'`;
}
