#!/usr/bin/env node

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import readline from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import { spawnSync } from "node:child_process";

const IMAGE = "ghcr.io/calganaygun/poke-pc:latest";
const CONTAINER_NAME = "poke-pc";
const STATE_VOLUME = "poke_pc_state";
const CREDENTIALS_PATH = join(homedir(), ".config", "poke", "credentials.json");

function run(cmd, args, options = {}) {
  const result = spawnSync(cmd, args, {
    encoding: "utf8",
    stdio: options.inherit ? "inherit" : "pipe",
    env: process.env,
    ...options
  });

  if (result.error) {
    throw result.error;
  }

  if ((result.status ?? 1) !== 0 && !options.allowFailure) {
    const stderr = (result.stderr ?? "").trim();
    const stdout = (result.stdout ?? "").trim();
    const details = stderr || stdout || `exit code ${String(result.status ?? 1)}`;
    throw new Error(`${cmd} ${args.join(" ")} failed: ${details}`);
  }

  return result;
}

function step(message) {
  console.log(`\n>> ${message}`);
}

function askYesNo(answer, defaultValue) {
  const normalized = answer.trim().toLowerCase();
  if (normalized.length === 0) {
    return defaultValue;
  }

  if (["y", "yes", "true", "1"].includes(normalized)) {
    return true;
  }

  if (["n", "no", "false", "0"].includes(normalized)) {
    return false;
  }

  return defaultValue;
}

async function main() {
  console.log("Poke PC Docker setup");
  console.log("====================");

  step("Checking Docker installation...");
  run("docker", ["--version"]);

  step("Checking Docker daemon status...");
  run("docker", ["info"]);

  const rl = readline.createInterface({ input, output });

  try {
    if (!existsSync(CREDENTIALS_PATH)) {
      console.log("\nNo poke login credentials found.");
      step("Running poke login for tunnel authentication...");
      run("poke", ["login"], { inherit: true });
    } else {
      console.log(`\nFound credentials at ${CREDENTIALS_PATH}`);
    }

    const webhookAnswer = await rl.question("Enable webhook integration? (y/N): ");
    const enableWebhook = askYesNo(webhookAnswer, false);

    let apiKey = "";
    if (enableWebhook) {
      const envApiKey = process.env.POKE_API_KEY ?? "";
      if (envApiKey.trim().length > 0) {
        apiKey = envApiKey.trim();
      } else {
        const typed = await rl.question("Enter POKE_API_KEY for webhook mode: ");
        apiKey = typed.trim();
      }

      if (apiKey.length === 0) {
        throw new Error("Webhook mode requires POKE_API_KEY.");
      }
    }

    const existingNames = run("docker", ["ps", "-a", "--format", "{{.Names}}"], {
      allowFailure: true
    }).stdout
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.length > 0);

    if (existingNames.includes(CONTAINER_NAME)) {
      const replaceAnswer = await rl.question(
        `Container '${CONTAINER_NAME}' already exists. Replace it? (Y/n): `
      );
      const replace = askYesNo(replaceAnswer, true);

      if (!replace) {
        console.log("Aborted. Existing container left untouched.");
        return;
      }

      step(`Removing existing container ${CONTAINER_NAME}...`);
      run("docker", ["rm", "-f", CONTAINER_NAME], { allowFailure: true });
    }

    step(`Creating Docker volume ${STATE_VOLUME}...`);
    run("docker", ["volume", "create", STATE_VOLUME]);

    step(`Pulling image ${IMAGE} (this can take a while)...`);
    run("docker", ["pull", IMAGE], { inherit: true });

    const args = [
      "run",
      "-d",
      "--name",
      CONTAINER_NAME,
      "-p",
      "3000:3000",
      "-e",
      "POKE_TUNNEL_NAME=poke-pc",
      "-e",
      "MCP_PUBLIC_URL=http://127.0.0.1:3000/mcp",
      "-e",
      `POKE_PC_AUTOREGISTER_WEBHOOK=${enableWebhook ? "true" : "false"}`,
      "-v",
      `${STATE_VOLUME}:/root/poke-pc`,
      "-v",
      `${join(homedir(), ".config", "poke")}:/root/.config/poke`
    ];

    if (enableWebhook) {
      args.push("-e", `POKE_API_KEY=${apiKey}`);
    }

    args.push(IMAGE);

    step("Starting container...");
    run("docker", args, { inherit: true });

    console.log("\nContainer started successfully.");
    console.log(`- Name: ${CONTAINER_NAME}`);
    console.log(`- Image: ${IMAGE}`);
    console.log("\nUseful commands:");
    console.log(`- docker logs -f ${CONTAINER_NAME}`);
    console.log(`- docker exec -it ${CONTAINER_NAME} tail -f /root/poke-pc/terminal/history.ndjson`);
    console.log(`- docker stop ${CONTAINER_NAME}`);
  } finally {
    rl.close();
  }
}

main().catch((error) => {
  console.error(`\nSetup failed: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
});
