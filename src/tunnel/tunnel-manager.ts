import { PokeTunnel, type TunnelInfo } from "poke";
import type { Logger } from "pino";
import type { AppConfig } from "../config/config.js";

const MAX_BACKOFF_MS = 30_000;

export class TunnelManager {
  private readonly config: AppConfig;
  private readonly logger: Logger;
  private running = false;
  private currentTunnel: PokeTunnel | undefined;
  private currentInfo: TunnelInfo | undefined;

  public constructor(config: AppConfig, logger: Logger) {
    this.config = config;
    this.logger = logger.child({ component: "tunnel" });
  }

  public get connected(): boolean {
    return this.currentTunnel?.connected ?? false;
  }

  public get info(): TunnelInfo | undefined {
    return this.currentInfo;
  }

  public async start(): Promise<void> {
    this.running = true;
    let attempt = 0;
    this.logger.info({ tunnelName: this.config.tunnelName }, "Tunnel manager loop started.");

    while (this.running) {
      try {
        this.logger.info({ attempt: attempt + 1 }, "Starting tunnel session attempt.");
        await this.startOneTunnelSession();
        attempt = 0;
      } catch (error) {
        if (!this.running) {
          break;
        }

        attempt += 1;
        const delay = Math.min(1000 * 2 ** (attempt - 1), MAX_BACKOFF_MS);
        this.logger.warn(
          { err: error, delayMs: delay, attempt },
          "Tunnel disconnected or failed; retrying."
        );
        await sleep(delay);
      }
    }

    this.logger.info("Tunnel manager loop stopped.");
  }

  public async stop(): Promise<void> {
    this.running = false;
    this.logger.info("Stopping tunnel manager.");

    if (this.currentTunnel) {
      await this.currentTunnel.stop().catch((error: unknown) => {
        this.logger.warn({ err: error }, "Error while stopping active tunnel.");
      });
    }

    this.currentTunnel = undefined;
    this.currentInfo = undefined;
  }

  private async startOneTunnelSession(): Promise<void> {
    const options: {
      url: string;
      name: string;
      baseUrl?: string;
      syncIntervalMs: number;
      cleanupOnStop: boolean;
    } = {
      url: this.config.mcpPublicUrl,
      name: this.config.tunnelName,
      syncIntervalMs: this.config.tunnel.syncIntervalMs,
      cleanupOnStop: true
    };

    if (this.config.pokeApiBaseUrl) {
      options.baseUrl = this.config.pokeApiBaseUrl;
    }

    const tunnel = new PokeTunnel(options);

    this.currentTunnel = tunnel;

    let disconnectedResolver: ((reason: string) => void) | undefined;
    let settled = false;
    const resolveDisconnect = (reason: string): void => {
      if (settled) {
        return;
      }

      settled = true;
      disconnectedResolver?.(reason);
    };

    const disconnected = new Promise<string>((resolve) => {
      disconnectedResolver = resolve;
    });

    tunnel.on("connected", (info) => {
      this.currentInfo = info;
      this.logger.info({ info }, "Tunnel connected.");
    });

    tunnel.on("toolsSynced", ({ toolCount }) => {
      this.logger.info({ toolCount }, "Tunnel tools synced.");
    });

    tunnel.on("oauthRequired", ({ authUrl }) => {
      this.logger.error({ authUrl }, "Tunnel requires OAuth interaction and cannot continue headless.");
      resolveDisconnect("oauthRequired");
    });

    tunnel.on("disconnected", () => {
      this.logger.warn("Tunnel disconnected.");
      resolveDisconnect("disconnected");
    });

    tunnel.on("error", (error) => {
      this.logger.error({ err: error }, "Tunnel emitted error.");
      resolveDisconnect("error");
    });

    await tunnel.start();
    const reason = await disconnected;

    await tunnel.stop().catch((error: unknown) => {
      this.logger.warn({ err: error }, "Error during tunnel stop after disconnect.");
    });

    this.currentTunnel = undefined;
    this.currentInfo = undefined;

    throw new Error(`Tunnel session ended: ${reason}`);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
