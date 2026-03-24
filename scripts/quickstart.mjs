#!/usr/bin/env node

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import readline from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import { spawnSync } from "node:child_process";
import { isLoggedIn, login } from "poke";

const isDev = process.env.POKE_PC_ENVIRONMENT === "dev";
const IMAGE_TAG = isDev ? "dev" : "latest";
const IMAGE = `ghcr.io/calganaygun/poke-pc:${IMAGE_TAG}`;
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
  console.log(`\n🔹 ${message}`);
}

function printHeader() {
  console.log("\n############################################");
  console.log("#                                          #");
  console.log("#        POKE-PC  QUICKSTART TUI           #");
  console.log("#                                          #");
  console.log("############################################\n");
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
  printHeader();
  console.log("🚀 Fast setup for Poke PC with Docker + OAuth credentials.\n");

  step("Checking Docker installation...");
  run("docker", ["--version"]);

  step("Checking Docker daemon status...");
  run("docker", ["info"]);

  const rl = readline.createInterface({ input, output });

  try {
    if (!existsSync(CREDENTIALS_PATH) || !isLoggedIn()) {
      console.log("\n🔐 No valid Poke credentials found.");
      step("Starting device login with the Poke SDK...");

      await login({
        openBrowser: false,
        onCode: ({ userCode, loginUrl }) => {
          console.log("\n🌐 Complete login in your browser:");
          console.log(`- URL: ${loginUrl}`);
          console.log(`- Code: ${userCode}\n`);
        }
      });

      console.log(`✅ Credentials saved to ${CREDENTIALS_PATH}`);
    } else {
      console.log(`\n✅ Found credentials at ${CREDENTIALS_PATH}`);
    }

    const webhookAnswer = await rl.question("Enable webhook integration? (Y/n): ");
    const enableWebhook = askYesNo(webhookAnswer, true);

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
        console.log("🛑 Aborted. Existing container left untouched.");
        return;
      }

      step(`Removing existing container ${CONTAINER_NAME}...`);
      run("docker", ["rm", "-f", CONTAINER_NAME], { allowFailure: true });
    }

    step(`Creating Docker volume ${STATE_VOLUME}...`);
    run("docker", ["volume", "create", STATE_VOLUME]);

    step(`Pulling image ${IMAGE} (this can take a while)...`);
    if (!isDev) {
      run("docker", ["pull", IMAGE], { inherit: true });
    } else {
      console.log(
        `🧪 Skipping pull in dev mode. Build the image locally with tag '${IMAGE_TAG}'.`
      );
    }

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

    args.push(IMAGE);

    step("Starting container...");
    run("docker", args, { inherit: true });

    console.log("\n✅ Container started successfully.");
    console.log(`- Name: ${CONTAINER_NAME}`);
    console.log(`- Image: ${IMAGE}`);
    console.log(`- Command notifications to Poke: ${enableWebhook ? "enabled" : "disabled"}`);
    console.log("\n🛠 Useful commands:");
    console.log(`- docker logs -f ${CONTAINER_NAME}`);
    console.log(`- docker exec -it ${CONTAINER_NAME} tail -f /root/poke-pc/terminal/history.ndjson`);
    console.log(`- docker stop ${CONTAINER_NAME}`);
  } finally {
    rl.close();
  }
}

main().catch((error) => {
  console.error(`\n❌ Setup failed: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
});
