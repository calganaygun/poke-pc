import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, resolve } from "node:path";
import { z } from "zod";

const envSchema = z.object({
  NODE_ENV: z.string().optional(),
  LOG_LEVEL: z.string().optional(),
  POKE_API: z.string().url().optional(),
  POKE_TUNNEL_NAME: z.string().min(1).default("poke-pc"),
  MCP_PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  MCP_HOST: z.string().default("0.0.0.0"),
  MCP_PUBLIC_URL: z.string().url().optional(),
  POKE_PC_STATE_DIR: z.string().optional(),
  POKE_PC_BOOTSTRAP_CONFIG: z.string().optional(),
  POKE_PC_BOOTSTRAP_COMMANDS: z.string().optional(),
  POKE_PC_BOOTSTRAP_STRICT: z
    .string()
    .optional()
    .transform((v) => (v ?? "true").toLowerCase() !== "false"),
  POKE_PC_RESTORE_SESSIONS: z
    .string()
    .optional()
    .transform((v) => (v ?? "true").toLowerCase() !== "false"),
  POKE_PC_AUTOREGISTER_WEBHOOK: z
    .string()
    .optional()
    .transform((v) => (v ?? "true").toLowerCase() !== "false"),
  POKE_PC_WEBHOOK_CONDITION: z
    .string()
    .default("When terminal commands are long-running or complete"),
  POKE_PC_WEBHOOK_ACTION: z
    .string()
    .default("Notify me with command progress heartbeat and completion details"),
  POKE_PC_LONG_RUNNING_THRESHOLD_MS: z.coerce.number().int().min(5000).default(60000),
  POKE_PC_HEARTBEAT_INTERVAL_MS: z.coerce.number().int().min(10000).default(30000),
  POKE_PC_MONITOR_INTERVAL_MS: z.coerce.number().int().min(2000).default(5000),
  POKE_PC_TUNNEL_SYNC_INTERVAL_MS: z.coerce.number().int().min(10000).default(300000)
});

export type AppConfig = {
  pokeApiBaseUrl: string | undefined;
  tunnelName: string;
  mcpPort: number;
  mcpHost: string;
  mcpPublicUrl: string;
  stateDir: string;
  bootstrap: {
    configPath?: string;
    commandList?: string;
    strict: boolean;
  };
  sessions: {
    restoreOnStartup: boolean;
  };
  webhook: {
    autoRegister: boolean;
    condition: string;
    action: string;
    longRunningThresholdMs: number;
    heartbeatIntervalMs: number;
    monitorIntervalMs: number;
  };
  tunnel: {
    syncIntervalMs: number;
  };
};

export function loadConfig(rawEnv: NodeJS.ProcessEnv = process.env): AppConfig {
  const env = envSchema.parse(rawEnv);

  const stateDir = resolvePath(env.POKE_PC_STATE_DIR ?? "/root/poke-pc");
  mkdirSync(stateDir, { recursive: true });

  const mcpPublicUrl =
    env.MCP_PUBLIC_URL ?? `http://127.0.0.1:${env.MCP_PORT.toString()}/mcp`;

  const bootstrap: AppConfig["bootstrap"] = {
    strict: env.POKE_PC_BOOTSTRAP_STRICT
  };

  const bootstrapConfigPath = env.POKE_PC_BOOTSTRAP_CONFIG;
  if (bootstrapConfigPath) {
    bootstrap.configPath = resolvePath(bootstrapConfigPath);
  }

  const bootstrapCommands = env.POKE_PC_BOOTSTRAP_COMMANDS;
  if (bootstrapCommands) {
    bootstrap.commandList = bootstrapCommands;
  }

  const config: AppConfig = {
    pokeApiBaseUrl: env.POKE_API,
    tunnelName: env.POKE_TUNNEL_NAME,
    mcpPort: env.MCP_PORT,
    mcpHost: env.MCP_HOST,
    mcpPublicUrl,
    stateDir,
    bootstrap,
    sessions: {
      restoreOnStartup: env.POKE_PC_RESTORE_SESSIONS
    },
    webhook: {
      autoRegister: env.POKE_PC_AUTOREGISTER_WEBHOOK,
      condition: env.POKE_PC_WEBHOOK_CONDITION,
      action: env.POKE_PC_WEBHOOK_ACTION,
      longRunningThresholdMs: env.POKE_PC_LONG_RUNNING_THRESHOLD_MS,
      heartbeatIntervalMs: env.POKE_PC_HEARTBEAT_INTERVAL_MS,
      monitorIntervalMs: env.POKE_PC_MONITOR_INTERVAL_MS
    },
    tunnel: {
      syncIntervalMs: env.POKE_PC_TUNNEL_SYNC_INTERVAL_MS
    }
  };

  mkdirSync(dirname(getWebhookStatePath(config)), { recursive: true });
  mkdirSync(dirname(getTerminalStatePath(config)), { recursive: true });

  return config;
}

export function getWebhookStatePath(config: AppConfig): string {
  return resolve(config.stateDir, "webhook", "webhook.json");
}

export function getTerminalStatePath(config: AppConfig): string {
  return resolve(config.stateDir, "terminal", "state.json");
}

function resolvePath(value: string): string {
  if (value.startsWith("~/")) {
    return resolve(homedir(), value.slice(2));
  }

  if (isAbsolute(value)) {
    return value;
  }

  return resolve(process.cwd(), value);
}
