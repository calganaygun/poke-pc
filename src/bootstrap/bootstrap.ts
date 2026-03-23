import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { parse as parseYaml } from "yaml";
import { z } from "zod";
import type { Logger } from "pino";
import type { AppConfig } from "../config/config.js";

const bootstrapSchema = z.object({
  strict: z.boolean().optional(),
  commands: z.array(z.string().min(1)).default([])
});

export async function runBootstrap(
  config: AppConfig,
  logger: Logger
): Promise<void> {
  const historyPath = resolve(config.stateDir, "terminal", "history.ndjson");
  mkdirSync(dirname(historyPath), { recursive: true });

  const steps = loadBootstrapSteps(config, logger);

  if (steps.commands.length === 0) {
    logger.info("No bootstrap commands configured.");
    return;
  }

  logger.info({ count: steps.commands.length }, "Running bootstrap commands.");

  for (const [index, command] of steps.commands.entries()) {
    const stepId = index + 1;
    logger.info({ stepId, command }, "Bootstrap command starting.");
    appendHistory(historyPath, "bootstrap_command_started", {
      stepId,
      command
    });

    const exitCode = await runShellCommand(command, logger.child({ component: "bootstrap", stepId }));

    if (exitCode === 0) {
      logger.info({ stepId }, "Bootstrap command finished successfully.");
      appendHistory(historyPath, "bootstrap_command_completed", {
        stepId,
        command,
        exitCode
      });
      continue;
    }

    appendHistory(historyPath, "bootstrap_command_failed", {
      stepId,
      command,
      exitCode
    });

    const message = `Bootstrap command ${stepId.toString()} failed with exit code ${exitCode.toString()}`;
    if (steps.strict) {
      throw new Error(message);
    }

    logger.warn({ stepId, exitCode }, `${message}; continuing due to non-strict mode.`);
  }
}

function appendHistory(path: string, type: string, data: Record<string, unknown>): void {
  const entry = {
    timestamp: new Date().toISOString(),
    type,
    ...data
  };

  appendFileSync(path, `${JSON.stringify(entry)}\n`);
}

function loadBootstrapSteps(config: AppConfig, logger: Logger): { commands: string[]; strict: boolean } {
  if (config.bootstrap.configPath) {
    if (!existsSync(config.bootstrap.configPath)) {
      throw new Error(`Bootstrap config file not found: ${config.bootstrap.configPath}`);
    }

    const raw = readFileSync(config.bootstrap.configPath, "utf8");
    const parsed = parseByExtension(config.bootstrap.configPath, raw);
    const validated = bootstrapSchema.parse(parsed);

    logger.info({ path: config.bootstrap.configPath, count: validated.commands.length }, "Loaded bootstrap config file.");

    return {
      commands: validated.commands,
      strict: validated.strict ?? config.bootstrap.strict
    };
  }

  if (config.bootstrap.commandList) {
    const commands = config.bootstrap.commandList
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.length > 0);

    return {
      commands,
      strict: config.bootstrap.strict
    };
  }

  return {
    commands: [],
    strict: config.bootstrap.strict
  };
}

function parseByExtension(path: string, content: string): unknown {
  const lower = path.toLowerCase();
  if (lower.endsWith(".yaml") || lower.endsWith(".yml")) {
    return parseYaml(content);
  }

  return JSON.parse(content);
}

function runShellCommand(command: string, logger: Logger): Promise<number> {
  return new Promise((resolve, reject) => {
    const child = spawn("bash", ["-lc", command], {
      stdio: ["ignore", "pipe", "pipe"],
      env: process.env
    });

    child.stdout.on("data", (chunk) => {
      const text = String(chunk).trim();
      if (text.length > 0) {
        logger.info({ output: text }, "bootstrap stdout");
      }
    });

    child.stderr.on("data", (chunk) => {
      const text = String(chunk).trim();
      if (text.length > 0) {
        logger.warn({ output: text }, "bootstrap stderr");
      }
    });

    child.on("error", (error) => reject(error));

    child.on("close", (code) => {
      resolve(code ?? 1);
    });
  });
}
