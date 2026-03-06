#!/usr/bin/env node
/**
 * Start Bastion AI Gateway in-process.
 * Outputs connection info as JSON, then keeps running until SIGTERM/SIGINT.
 *
 * Usage: node start.mjs [--port PORT] [--silent] [--db-path PATH]
 */
import { parseArgs } from "node:util";

// Resolve @aion0/bastion — fallback to /app for Docker/pnpm environments
// where the script runs outside the app's node_modules tree.
let bastion;
try {
  bastion = await import("@aion0/bastion");
} catch {
  try {
    const { pathToFileURL } = await import("node:url");
    const fs = await import("node:fs");
    // pnpm stores packages in node_modules/.pnpm — read the symlinked package.json
    // to find the actual entry point.
    const pkgDir = "/app/node_modules/@aion0/bastion";
    const pkgJson = JSON.parse(fs.readFileSync(`${pkgDir}/package.json`, "utf8"));
    const entry = pkgJson.exports?.["."]?.import ?? pkgJson.main ?? "dist/index.js";
    bastion = await import(pathToFileURL(`${pkgDir}/${entry}`).href);
  } catch (e) {
    console.error("Cannot find @aion0/bastion. Install it: pnpm add -w @aion0/bastion");
    console.error("Detail:", e.message);
    process.exit(1);
  }
}

const { createServer } = bastion;

const { values } = parseArgs({
  options: {
    port: { type: "string", default: "0" },
    silent: { type: "boolean", default: false },
    "db-path": { type: "string" },
  },
  strict: false,
});

const server = await createServer({
  port: parseInt(values.port, 10),
  silent: values.silent,
  dbPath: values["db-path"],
  skipPidFile: true,
});

const connectionInfo = {
  port: server.port,
  host: server.host,
  url: server.url,
  dashboardUrl: server.dashboardUrl,
  authToken: server.authToken,
  caCertPath: server.caCertPath,
};

// Output connection info as JSON (single line)
console.log(JSON.stringify(connectionInfo));

// Persist connection info so agents can read it
import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
const bastionDir = join(process.env.HOME || "/home/node", ".bastion");
mkdirSync(bastionDir, { recursive: true });
writeFileSync(join(bastionDir, "connection.json"), JSON.stringify(connectionInfo, null, 2));

server.on("dlp:finding", (e) => {
  process.stderr.write(`[bastion:dlp] ${e.patternName} on ${e.requestId} (${e.action})\n`);
});
server.on("toolguard:alert", (e) => {
  process.stderr.write(`[bastion:guard] ${e.toolName} — ${e.ruleName} (${e.severity})\n`);
});

const shutdown = async () => {
  await server.close();
  process.exit(0);
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
