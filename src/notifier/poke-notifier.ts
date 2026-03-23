import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { Poke } from "poke";
import type { Logger } from "pino";
import type { AppConfig } from "../config/config.js";
import type { CommandRecord } from "../terminal/terminal-manager.js";
import type { PokeOptions } from "poke";

type WebhookState = {
  triggerId: string;
  webhookUrl: string;
  webhookToken: string;
};

export class PokeNotifier {
  private readonly config: AppConfig;
  private readonly logger: Logger;
  private readonly statePath: string;
  private readonly poke: Poke;
  private webhook?: WebhookState;

  public constructor(config: AppConfig, statePath: string, logger: Logger) {
    this.config = config;
    this.statePath = statePath;
    this.logger = logger.child({ component: "notifier" });

    const options: PokeOptions = {};

    if (config.pokeApiKey) {
      options.apiKey = config.pokeApiKey;
    }

    if (config.pokeApiBaseUrl) {
      options.baseUrl = config.pokeApiBaseUrl;
    }

    this.poke = new Poke(options);
  }

  public async init(): Promise<void> {
    mkdirSync(dirname(this.statePath), { recursive: true });

    if (!this.config.pokeApiKey) {
      this.logger.info("Webhook integration disabled because POKE_API_KEY is not set.");
      return;
    }

    const persisted = this.loadWebhookState();
    if (persisted) {
      this.webhook = persisted;
      this.logger.info("Using persisted webhook registration.");
      return;
    }

    if (!this.config.webhook.autoRegister) {
      this.logger.warn("Webhook auto-registration disabled and no persisted webhook found.");
      return;
    }

    try {
      const created = await this.poke.createWebhook({
        condition: this.config.webhook.condition,
        action: this.config.webhook.action
      });

      this.webhook = {
        triggerId: created.triggerId,
        webhookUrl: created.webhookUrl,
        webhookToken: created.webhookToken
      };

      this.persistWebhookState(this.webhook);
      this.logger.info({ triggerId: created.triggerId }, "Webhook registered and persisted.");
    } catch (error) {
      if (isPermissionError(error)) {
        this.logger.warn(
          { err: error },
          "Webhook auto-registration skipped due to API key permission scope. Runtime will continue without webhook notifications."
        );
        return;
      }

      throw error;
    }
  }

  public async sendLongRunningStarted(command: CommandRecord): Promise<void> {
    await this.send("command.long_running_started", command, {
      elapsedMs: Date.now() - Date.parse(command.startedAt)
    });
  }

  public async sendHeartbeat(command: CommandRecord): Promise<void> {
    await this.send("command.heartbeat", command, {
      elapsedMs: Date.now() - Date.parse(command.startedAt)
    });
  }

  public async sendCompletion(command: CommandRecord): Promise<void> {
    await this.send("command.completed", command, {
      elapsedMs: Date.now() - Date.parse(command.startedAt),
      status: command.status,
      exitCode: command.exitCode ?? null,
      endedAt: command.endedAt ?? null
    });
  }

  private async send(
    eventName: string,
    command: CommandRecord,
    payload: Record<string, unknown>
  ): Promise<void> {
    if (!this.webhook) {
      this.logger.debug({ eventName, commandId: command.id }, "Skipping webhook send; no webhook configured.");
      return;
    }

    await this.poke.sendWebhook({
      webhookUrl: this.webhook.webhookUrl,
      webhookToken: this.webhook.webhookToken,
      data: {
        event: eventName,
        commandId: command.id,
        sessionName: command.sessionName,
        windowName: command.windowName,
        command: command.command,
        startedAt: command.startedAt,
        ...payload
      }
    });
  }

  private loadWebhookState(): WebhookState | undefined {
    if (!existsSync(this.statePath)) {
      return undefined;
    }

    try {
      const raw = readFileSync(this.statePath, "utf8");
      const parsed = JSON.parse(raw) as Partial<WebhookState>;
      if (!parsed.triggerId || !parsed.webhookUrl || !parsed.webhookToken) {
        return undefined;
      }

      return {
        triggerId: parsed.triggerId,
        webhookUrl: parsed.webhookUrl,
        webhookToken: parsed.webhookToken
      };
    } catch {
      return undefined;
    }
  }

  private persistWebhookState(state: WebhookState): void {
    writeFileSync(this.statePath, JSON.stringify(state, null, 2), {
      mode: 0o600
    });
  }
}

function isPermissionError(error: unknown): boolean {
  const message =
    typeof error === "object" && error !== null && "message" in error
      ? String((error as { message: unknown }).message)
      : String(error);

  const normalized = message.toLowerCase();
  return normalized.includes("doesn't have permission") || normalized.includes("permission");
}
