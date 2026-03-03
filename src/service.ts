import type { OpenClawPluginService } from "openclaw/plugin-sdk";

interface BastionPluginConfig {
  autoStart?: boolean;
  port?: number;
  silent?: boolean;
  logLevel?: "debug" | "info" | "warn" | "error";
  setProxy?: boolean;
}

export function createBastionService(): OpenClawPluginService {
  let server: import("@aion0/bastion").BastionServer | null = null;

  return {
    id: "bastion",

    async start(ctx) {
      const cfg = (ctx.pluginConfig ?? {}) as BastionPluginConfig;
      if (cfg.autoStart === false) {
        ctx.logger.info("[bastion] autoStart disabled, skipping");
        return;
      }

      try {
        // Resolve @aion0/bastion — fallback to /app for Docker/pnpm environments
        let bastionMod: typeof import("@aion0/bastion");
        try {
          bastionMod = await import("@aion0/bastion");
        } catch {
          const { pathToFileURL } = await import("node:url");
          const fs = await import("node:fs");
          const pkgDir = "/app/node_modules/@aion0/bastion";
          const pkgJson = JSON.parse(fs.readFileSync(`${pkgDir}/package.json`, "utf8"));
          const entry = pkgJson.exports?.["."]?.import ?? pkgJson.main ?? "dist/index.js";
          bastionMod = await import(pathToFileURL(`${pkgDir}/${entry}`).href);
        }
        const { createServer } = bastionMod;
        server = await createServer({
          port: cfg.port ?? 0,
          silent: cfg.silent ?? true,
          logLevel: cfg.logLevel ?? "info",
          skipPidFile: true,
        });

        // Store reference for hooks
        (globalThis as Record<string, unknown>).__bastionServer = server;

        ctx.logger.info(
          `[bastion] Gateway started — ${server.url} | dashboard: ${server.dashboardUrl}`,
        );

        // Set proxy env vars so OpenClaw LLM calls route through Bastion
        if (cfg.setProxy) {
          process.env.HTTPS_PROXY = server.url;
          process.env.NODE_EXTRA_CA_CERTS = server.caCertPath;
          ctx.logger.info(
            `[bastion] Proxy env set: HTTPS_PROXY=${server.url} CA=${server.caCertPath}`,
          );
        }

        // Forward Bastion events to OpenClaw logger
        server.on("dlp:finding", (e) => {
          ctx.logger.warn(
            `[bastion:dlp] ${e.patternName} on request ${e.requestId} (${e.action}, ${e.direction})`,
          );
        });

        server.on("toolguard:alert", (e) => {
          ctx.logger.warn(
            `[bastion:guard] ${e.toolName} — ${e.ruleName} (${e.severity}, ${e.action})`,
          );
        });

        server.on("request:complete", (e) => {
          ctx.logger.debug(
            `[bastion] ${e.provider}/${e.model} ${e.statusCode} ${e.latencyMs}ms in=${e.usage.inputTokens} out=${e.usage.outputTokens}`,
          );
        });
      } catch (err) {
        ctx.logger.error(`[bastion] Failed to start: ${(err as Error).message}`);
      }
    },

    async stop() {
      if (server) {
        await server.close();
        server = null;
        (globalThis as Record<string, unknown>).__bastionServer = undefined;

        // Clean up proxy env
        if (process.env.HTTPS_PROXY?.includes("bastion")) {
          delete process.env.HTTPS_PROXY;
          delete process.env.NODE_EXTRA_CA_CERTS;
        }
      }
    },
  };
}
