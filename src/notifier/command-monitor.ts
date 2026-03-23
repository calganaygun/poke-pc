import type { Logger } from "pino";
import type { AppConfig } from "../config/config.js";
import type { PokeNotifier } from "./poke-notifier.js";
import type { TerminalManager } from "../terminal/terminal-manager.js";

export class CommandMonitor {
  private readonly config: AppConfig;
  private readonly terminal: TerminalManager;
  private readonly notifier: PokeNotifier;
  private readonly logger: Logger;
  private timer: NodeJS.Timeout | undefined;

  public constructor(
    config: AppConfig,
    terminal: TerminalManager,
    notifier: PokeNotifier,
    logger: Logger
  ) {
    this.config = config;
    this.terminal = terminal;
    this.notifier = notifier;
    this.logger = logger.child({ component: "command-monitor" });
  }

  public start(): void {
    if (this.timer) {
      return;
    }

    this.logger.info(
      {
        monitorIntervalMs: this.config.webhook.monitorIntervalMs,
        longRunningThresholdMs: this.config.webhook.longRunningThresholdMs,
        heartbeatIntervalMs: this.config.webhook.heartbeatIntervalMs
      },
      "Command monitor started."
    );

    this.timer = setInterval(() => {
      void this.tick();
    }, this.config.webhook.monitorIntervalMs);

    this.timer.unref();
    void this.tick();
  }

  public stop(): void {
    if (!this.timer) {
      return;
    }

    clearInterval(this.timer);
    this.timer = undefined;
    this.logger.info("Command monitor stopped.");
  }

  private async tick(): Promise<void> {
    try {
      await this.terminal.refreshAllCommandStatuses();

      for (const command of this.terminal.listCommands(500)) {
        if (command.status === "running") {
          await this.handleRunningCommand(command.id);
          continue;
        }

        if (!command.completionNotified) {
          await this.notifier.sendCompletion(command);
          this.terminal.markCompletionNotified(command.id);
          this.logger.info({ commandId: command.id }, "Completion notification sent.");
        }
      }
    } catch (error) {
      this.logger.error({ err: error }, "Command monitor tick failed.");
    }
  }

  private async handleRunningCommand(commandId: string): Promise<void> {
    const command = this.terminal.getCommandById(commandId);
    if (!command || command.status !== "running") {
      return;
    }

    const now = new Date();
    const elapsedMs = now.getTime() - Date.parse(command.startedAt);

    if (elapsedMs < this.config.webhook.longRunningThresholdMs) {
      return;
    }

    if (!command.longRunningNotified) {
      await this.notifier.sendLongRunningStarted(command);
      this.terminal.markLongRunningNotified(command.id, now);
      this.logger.info({ commandId: command.id }, "Long-running notification sent.");
      return;
    }

    const lastHeartbeatMs = command.lastHeartbeatAt
      ? Date.parse(command.lastHeartbeatAt)
      : 0;

    if (now.getTime() - lastHeartbeatMs >= this.config.webhook.heartbeatIntervalMs) {
      await this.notifier.sendHeartbeat(command);
      this.terminal.markHeartbeat(command.id, now);
      this.logger.info({ commandId: command.id }, "Heartbeat notification sent.");
    }
  }
}
