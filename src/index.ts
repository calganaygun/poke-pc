import { loadConfig, getTerminalStatePath, getWebhookStatePath } from "./config/config.js";
import { logger } from "./logger.js";
import { runBootstrap } from "./bootstrap/bootstrap.js";
import { TerminalManager } from "./terminal/terminal-manager.js";
import { PokeNotifier } from "./notifier/poke-notifier.js";
import { CommandMonitor } from "./notifier/command-monitor.js";
import { startMcpServer } from "./mcp/server.js";
import { TunnelManager } from "./tunnel/tunnel-manager.js";
import { ensurePokeLogin } from "./auth/poke-auth.js";

async function main(): Promise<void> {
  const config = loadConfig();
  const appLogger = logger.child({ component: "main" });

  appLogger.info(
    {
      mcpHost: config.mcpHost,
      mcpPort: config.mcpPort,
      tunnelName: config.tunnelName,
      mcpPublicUrl: config.mcpPublicUrl
    },
    "Starting Poke PC runtime."
  );

  await ensurePokeLogin(config, logger);

  const terminal = new TerminalManager(getTerminalStatePath(config), logger);
  await terminal.init(config.sessions.restoreOnStartup);

  await runBootstrap(config, logger);

  const notifier = new PokeNotifier(config, getWebhookStatePath(config), logger);
  await notifier.init();

  const monitor = new CommandMonitor(config, terminal, notifier, logger);
  monitor.start();

  const mcp = await startMcpServer({ config, terminal, logger });

  const tunnel = new TunnelManager(config, logger);
  const tunnelPromise = tunnel.start();

  const shutdown = async (signal: string): Promise<void> => {
    appLogger.info({ signal }, "Shutdown requested.");
    monitor.stop();

    await Promise.allSettled([tunnel.stop(), mcp.close()]);
    process.exit(0);
  };

  process.on("SIGINT", () => {
    void shutdown("SIGINT");
  });

  process.on("SIGTERM", () => {
    void shutdown("SIGTERM");
  });

  await tunnelPromise;
}

main().catch((error) => {
  logger.error({ err: error }, "Fatal startup error.");
  process.exit(1);
});
