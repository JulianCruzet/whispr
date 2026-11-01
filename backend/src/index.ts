import { createServer } from "node:http";
import { WebSocketServer } from "ws";
import { Brain } from "./brain/index.js";
import { config, logIntegrations } from "./config.js";
import type { ServerEvent, Speaker } from "./protocol.js";
import { broadcast, dashboards, PhoneSession } from "./session.js";

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");

  if (req.method === "GET" && url.pathname === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
    return;
  }

  // Run the brain on a typed line, no audio needed:
  //   curl -X POST localhost:8787/debug/turn -d '{"text":"wait you saw her live?","speaker":"them"}'
  if (req.method === "POST" && url.pathname === "/debug/turn") {
    const body = JSON.parse((await readBody(req)) || "{}") as { text?: string; speaker?: Speaker };
    const events: ServerEvent[] = [];
    const brain = new Brain({
      send: (e) => {
        events.push(e);
        broadcast(e);
      },
      say: async () => {},
    });
    await brain.onTurn(body.text ?? "", body.speaker ?? "them");
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(events, null, 2));
    return;
  }

  res.writeHead(404).end();
});

const phoneWss = new WebSocketServer({ noServer: true });
const dashboardWss = new WebSocketServer({ noServer: true });

server.on("upgrade", (req, socket, head) => {
  const { pathname } = new URL(req.url ?? "/", "http://localhost");
  if (pathname === "/ws") {
    phoneWss.handleUpgrade(req, socket, head, (ws) => new PhoneSession(ws));
  } else if (pathname === "/ws/dashboard") {
    dashboardWss.handleUpgrade(req, socket, head, (ws) => {
      dashboards.add(ws);
      ws.on("close", () => dashboards.delete(ws));
    });
  } else {
    socket.destroy();
  }
});

server.listen(config.port, () => {
  console.log(`whispr backend on :${config.port}  (phone: /ws, dashboard: /ws/dashboard)`);
  logIntegrations();
});

function readBody(req: import("node:http").IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (chunk) => (data += chunk));
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });
}
