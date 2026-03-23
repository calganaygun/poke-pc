import { randomUUID } from "node:crypto";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { createMcpExpressApp } from "@modelcontextprotocol/sdk/server/express.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";
import type { Logger } from "pino";
import { z } from "zod";
import type { AppConfig } from "../config/config.js";
import type { TerminalManager } from "../terminal/terminal-manager.js";
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js";
import type { Request, Response } from "express";

export type RunningMcpServer = {
  close: () => Promise<void>;
};

type Dependencies = {
  config: AppConfig;
  terminal: TerminalManager;
  logger: Logger;
};

export async function startMcpServer({
  config,
  terminal,
  logger
}: Dependencies): Promise<RunningMcpServer> {
  const app = createMcpExpressApp({ host: config.mcpHost });
  const transportBySession: Record<string, StreamableHTTPServerTransport> = {};

  const mcpPostHandler = async (req: Request, res: Response): Promise<void> => {
    const sessionIdHeader = req.headers["mcp-session-id"];
    const sessionId = typeof sessionIdHeader === "string" ? sessionIdHeader : undefined;

    try {
      let transport: StreamableHTTPServerTransport | undefined;

      if (sessionId) {
        transport = transportBySession[sessionId];
      } else if (isInitializeRequest(req.body)) {
        transport = new StreamableHTTPServerTransport({
          sessionIdGenerator: () => randomUUID(),
          onsessioninitialized: (newSessionId) => {
            transportBySession[newSessionId] = transport as StreamableHTTPServerTransport;
          }
        });

        transport.onclose = () => {
          const sid = transport?.sessionId;
          if (sid && transportBySession[sid]) {
            delete transportBySession[sid];
          }
        };

        const server = buildServer(terminal, logger);
        await server.connect(transport as unknown as Transport);
      }

      if (!transport) {
        res.status(400).json({
          jsonrpc: "2.0",
          error: {
            code: -32000,
            message: "Bad Request: no valid MCP session found"
          },
          id: null
        });
        return;
      }

      await transport.handleRequest(req, res, req.body);
    } catch (error) {
      logger.error({ err: error }, "MCP POST handler failed.");
      if (!res.headersSent) {
        res.status(500).json({
          jsonrpc: "2.0",
          error: {
            code: -32603,
            message: "Internal server error"
          },
          id: null
        });
      }
    }
  };

  app.post("/mcp", mcpPostHandler);

  app.get("/mcp", async (req: Request, res: Response) => {
    const sessionIdHeader = req.headers["mcp-session-id"];
    const sessionId = typeof sessionIdHeader === "string" ? sessionIdHeader : undefined;
    if (!sessionId || !transportBySession[sessionId]) {
      res.status(400).send("Invalid or missing session ID");
      return;
    }

    await transportBySession[sessionId].handleRequest(req, res);
  });

  app.delete("/mcp", async (req: Request, res: Response) => {
    const sessionIdHeader = req.headers["mcp-session-id"];
    const sessionId = typeof sessionIdHeader === "string" ? sessionIdHeader : undefined;

    if (!sessionId || !transportBySession[sessionId]) {
      res.status(400).send("Invalid or missing session ID");
      return;
    }

    await transportBySession[sessionId].handleRequest(req, res);
  });

  app.get("/health", (_req, res) => {
    res.status(200).json({
      ok: true,
      service: "poke-pc",
      timestamp: new Date().toISOString()
    });
  });

  const server = await new Promise<import("node:http").Server>((resolve, reject) => {
    const listener = app.listen(config.mcpPort, config.mcpHost, () => resolve(listener));
    listener.on("error", reject);
  });

  logger.info(
    { host: config.mcpHost, port: config.mcpPort },
    "MCP HTTP server listening."
  );

  return {
    close: async () => {
      for (const transport of Object.values(transportBySession)) {
        await transport.close().catch(() => undefined);
      }

      await new Promise<void>((resolve, reject) => {
        server.close((error) => {
          if (error) {
            reject(error);
            return;
          }
          resolve();
        });
      });
    }
  };
}

function buildServer(terminal: TerminalManager, logger: Logger): McpServer {
  const server = new McpServer(
    {
      name: "poke-pc",
      version: "0.1.0"
    },
    {
      capabilities: {
        logging: {}
      }
    }
  );

  server.registerTool(
    "terminal_create_session",
    {
      description: "Create or ensure a tmux session exists",
      inputSchema: z.object({
        sessionName: z.string().min(1)
      })
    },
    async ({ sessionName }) => {
      await terminal.ensureSession(sessionName);
      return {
        content: [{ type: "text", text: `Session ready: ${sessionName}` }],
        structuredContent: { sessionName }
      };
    }
  );

  server.registerTool(
    "terminal_list_sessions",
    {
      description: "List tmux sessions known by the server"
    },
    async () => {
      const sessions = await terminal.listActiveTmuxSessions();
      return {
        content: [{ type: "text", text: sessions.join("\n") || "No sessions" }],
        structuredContent: { sessions }
      };
    }
  );

  server.registerTool(
    "terminal_run_command",
    {
      description: "Run a shell command inside a dedicated tmux window within a session",
      inputSchema: z.object({
        sessionName: z.string().min(1),
        command: z.string().min(1)
      })
    },
    async ({ sessionName, command }) => {
      const commandRecord = await terminal.runCommand(sessionName, command);
      return {
        content: [
          {
            type: "text",
            text: `Started command ${commandRecord.id} in ${commandRecord.sessionName}:${commandRecord.windowName}`
          }
        ],
        structuredContent: commandRecord
      };
    }
  );

  server.registerTool(
    "terminal_get_command_status",
    {
      description: "Get status for a previously started command",
      inputSchema: z.object({
        commandId: z.string().uuid()
      })
    },
    async ({ commandId }) => {
      await terminal.refreshAllCommandStatuses();
      const command = terminal.getCommandById(commandId);

      if (!command) {
        return {
          content: [{ type: "text", text: `Command not found: ${commandId}` }],
          isError: true
        };
      }

      return {
        content: [
          {
            type: "text",
            text: `Status: ${command.status} exit=${command.exitCode ?? "n/a"}`
          }
        ],
        structuredContent: command
      };
    }
  );

  server.registerTool(
    "terminal_capture_output",
    {
      description: "Capture recent output lines from a command window",
      inputSchema: z.object({
        commandId: z.string().uuid(),
        lines: z.number().int().min(1).max(1000).default(200)
      })
    },
    async ({ commandId, lines }) => {
      const output = await terminal.captureOutput(commandId, lines);
      return {
        content: [{ type: "text", text: output || "No output" }],
        structuredContent: { commandId, lines, output }
      };
    }
  );

  server.registerTool(
    "terminal_kill_session",
    {
      description: "Kill a tmux session",
      inputSchema: z.object({
        sessionName: z.string().min(1)
      })
    },
    async ({ sessionName }) => {
      await terminal.killSession(sessionName);
      return {
        content: [{ type: "text", text: `Killed session ${sessionName}` }],
        structuredContent: { sessionName }
      };
    }
  );

  server.registerTool(
    "terminal_list_commands",
    {
      description: "List latest commands and statuses",
      inputSchema: z.object({
        limit: z.number().int().min(1).max(200).default(50)
      })
    },
    async ({ limit }) => {
      const commands = terminal.listCommands(limit);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(commands, null, 2)
          }
        ],
        structuredContent: { commands }
      };
    }
  );

  logger.info("MCP tools registered.");
  return server;
}
