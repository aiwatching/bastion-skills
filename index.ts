import type { OpenClawPluginApi } from "openclaw/plugin-sdk";
import { createBastionService } from "./src/service.js";

const plugin = {
  id: "bastion",
  name: "Bastion AI Gateway",
  description: "Local-first security gateway — DLP scanning, tool guard, audit logging for LLM requests.",
  configSchema: {
    type: "object",
    additionalProperties: false,
    properties: {
      autoStart: { type: "boolean", default: true },
      port: { type: "number", default: 0 },
      silent: { type: "boolean", default: true },
      logLevel: { type: "string", enum: ["debug", "info", "warn", "error"], default: "info" },
      setProxy: { type: "boolean", default: false },
    },
  },
  register(api: OpenClawPluginApi) {
    // Register background service — starts/stops Bastion with the gateway
    api.registerService(createBastionService());

    // Hook: log DLP/tool-guard events to OpenClaw logger
    api.on("llm_output", async (payload) => {
      const state = (globalThis as Record<string, unknown>).__bastionServer as
        | import("@aion0/bastion").BastionServer
        | undefined;
      if (!state) return {};

      // Bastion handles scanning via proxy — this hook is for observability only
      api.logger.debug(
        `[bastion] LLM output observed: provider=${payload.provider} model=${payload.model} tokens=${payload.usage?.output ?? 0}`,
      );
      return {};
    });
  },
};

export default plugin;
