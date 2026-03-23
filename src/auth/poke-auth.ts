import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { isLoggedIn, login, type LoginOptions } from "poke";
import type { Logger } from "pino";
import type { AppConfig } from "../config/config.js";

function getCredentialsPath(): string {
  const xdgConfigHome = process.env.XDG_CONFIG_HOME;
  const configRoot = xdgConfigHome ? xdgConfigHome : join(homedir(), ".config");
  return join(configRoot, "poke", "credentials.json");
}

export async function ensurePokeLogin(config: AppConfig, logger: Logger): Promise<void> {
  if (config.pokeApiKey) {
    logger.info("POKE_API_KEY provided; skipping poke login bootstrap.");
    return;
  }

  const credentialsPath = getCredentialsPath();
  const credentialsPresent = existsSync(credentialsPath);

  if (credentialsPresent && isLoggedIn()) {
    logger.info({ credentialsPath }, "Using existing poke login credentials.");
    return;
  }

  logger.warn(
    { credentialsPath },
    "No Poke API key or credentials found. Starting interactive device login."
  );

  const loginOptions: LoginOptions = {
    openBrowser: false,
    onCode: ({ userCode, loginUrl }) => {
      logger.warn(
        { userCode, loginUrl },
        "Complete login in browser, then restart container once authenticated."
      );
    }
  };

  if (config.pokeApiBaseUrl) {
    loginOptions.baseUrl = config.pokeApiBaseUrl;
  }

  await login(loginOptions);

  logger.info({ credentialsPath }, "Poke login completed and credentials saved.");
}
