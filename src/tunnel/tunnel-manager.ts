import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { PokeTunnel, getToken, type TunnelInfo } from "poke";
import type { Logger } from "pino";
import type { AppConfig } from "../config/config.js";

const MAX_BACKOFF_MS = 30_000;

type TunnelState = {
  connectionId?: string;
};

export class TunnelManager {
  private readonly config: AppConfig;
  private readonly statePath: string;
  private readonly logger: Logger;
  private running = false;
  private currentTunnel: PokeTunnel | undefined;
  private currentInfo: TunnelInfo | undefined;
  private connectionId: string | undefined;

  public constructor(config: AppConfig, statePath: string, logger: Logger) {
    this.config = config;
    this.statePath = statePath;
    this.logger = logger.child({ component: "tunnel" });
    this.connectionId = this.loadState().connectionId;
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

    if (this.connectionId) {
      this.logger.info(
        { connectionId: this.connectionId, statePath: this.statePath },
        "Found persisted MCP connection ID in state folder; attempting stale cleanup before reconnect."
      );
      await this.cleanupConnection();
    }

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

  public async cleanupConnection(): Promise<void> {
    const connectionId = this.connectionId;
    if (!connectionId) {
      return;
    }

    const token = getToken();
    if (!token) {
      this.logger.warn({ connectionId }, "No auth token available; skipping MCP connection cleanup.");
      return;
    }

    const base = this.config.pokeApiBaseUrl ?? "https://poke.com/api/v1";
    const url = `${base}/mcp/connections/${encodeURIComponent(connectionId)}`;

    try {
      const response = await fetch(url, {
        method: "DELETE",
        headers: { Authorization: `Bearer ${token}` }
      });

      if (response.ok || response.status === 404) {
        this.logger.info({ connectionId, status: response.status }, "MCP connection cleanup completed.");
        this.connectionId = undefined;
        this.saveState({});
        return;
      }

      this.logger.warn(
        { connectionId, status: response.status },
        "MCP connection cleanup request returned non-success status."
      );
    } catch (error) {
      this.logger.warn({ err: error, connectionId }, "Failed to cleanup MCP connection.");
    }
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
      this.connectionId = info.connectionId;
      this.saveState({ connectionId: info.connectionId });
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

  private loadState(): TunnelState {
    if (!existsSync(this.statePath)) {
      return {};
    }

    try {
      const raw = readFileSync(this.statePath, "utf8");
      const parsed = JSON.parse(raw) as Partial<TunnelState>;
      if (typeof parsed.connectionId === "string" && parsed.connectionId.length > 0) {
        return { connectionId: parsed.connectionId };
      }
      return {};
    } catch {
      return {};
    }
  }

  private saveState(state: TunnelState): void {
    writeFileSync(this.statePath, JSON.stringify(state, null, 2), {
      mode: 0o600
    });
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
