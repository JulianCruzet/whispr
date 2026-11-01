// Audio gateway: the phone's WebSocket, speech-to-text and text-to-speech.
// Decisions (whisper or not, what to say, photo tasks) come from the brain in backend/app.

import { createServer } from "node:http";
import { WebSocketServer } from "ws";
import { config, logIntegrations } from "./config.js";
import { dashboards, PhoneSession } from "./session.js";

const server = createServer((req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");

  if (req.method === "GET" && url.pathname === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: true, elevenlabs: !!config.elevenlabs.apiKey, brain: config.brain.url }));
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
  console.log(`whispr gateway on :${config.port}  (phone: /ws, dashboard: /ws/dashboard)`);
  logIntegrations();
});
