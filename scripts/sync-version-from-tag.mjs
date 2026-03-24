#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

function normalizeTag(input) {
  const raw = (input || "").trim();
  if (!raw) {
    throw new Error("Missing tag/version input. Pass vX.Y.Z or X.Y.Z.");
  }
  const version = raw.startsWith("v") ? raw.slice(1) : raw;
  const semverLike = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/;
  if (!semverLike.test(version)) {
    throw new Error(`Invalid version '${raw}'. Expected vX.Y.Z or X.Y.Z.`);
  }
  return version;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

const input = process.argv[2] || process.env.RELEASE_VERSION || process.env.GITHUB_REF_NAME;
const version = normalizeTag(input);

const packageJsonPath = path.join(repoRoot, "package.json");
const packageLockPath = path.join(repoRoot, "package-lock.json");
const macVersionPath = path.join(repoRoot, "macos-app", "VERSION");

const pkg = readJson(packageJsonPath);
pkg.version = version;
writeJson(packageJsonPath, pkg);

if (fs.existsSync(packageLockPath)) {
  const lock = readJson(packageLockPath);
  lock.version = version;
  if (lock.packages && lock.packages[""]) {
    lock.packages[""].version = version;
  }
  writeJson(packageLockPath, lock);
}

fs.writeFileSync(macVersionPath, `${version}\n`, "utf8");

console.log(version);
