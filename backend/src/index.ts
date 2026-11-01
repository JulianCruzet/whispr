// Audio gateway: the phone's WebSocket, speech-to-text and text-to-speech.
// Decisions (whisper or not, what to say, photo tasks) come from the brain in backend/app.

import { createServer, type IncomingMessage } from "node:http";
import { WebSocketServer } from "ws";
import { config, logIntegrations } from "./config.js";
import { getImage } from "./media.js";
import { dashboards, PhoneSession } from "./session.js";

const server = createServer((req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");

  if (req.method === "GET" && url.pathname === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: true, elevenlabs: !!config.elevenlabs.apiKey, brain: config.brain.url }));
    return;
  }

  // Proof photos relayed for the phone (see media.ts).
  const media = req.method === "GET" && url.pathname.match(/^\/media\/([0-9a-f-]{36})$/);
  if (media) {
    const image = getImage(media[1]);
    if (!image) {
      res.writeHead(404).end();
      return;
    }
    res.writeHead(200, {
      "Content-Type": image.contentType,
      "Content-Length": image.body.length,
      "Cache-Control": "private, max-age=3600",
    });
    res.end(image.body);
    return;
  }

  res.writeHead(404).end();
});

/** How the phone reached us, e.g. https://whispr.onrender.com behind Render or a tunnel. */
function publicBaseUrl(req: IncomingMessage): string {
  const header = (name: string) => {
    const value = req.headers[name];
    return (Array.isArray(value) ? value[0] : value)?.split(",")[0].trim();
  };
  const proto = header("x-forwarded-proto") ?? ("encrypted" in req.socket && req.socket.encrypted ? "https" : "http");
  const host = header("x-forwarded-host") ?? header("host") ?? `localhost:${config.port}`;
  return `${proto}://${host}`;
}

const phoneWss = new WebSocketServer({ noServer: true });
const dashboardWss = new WebSocketServer({ noServer: true });

server.on("upgrade", (req, socket, head) => {
  const { pathname } = new URL(req.url ?? "/", "http://localhost");
  if (pathname === "/ws") {
    phoneWss.handleUpgrade(req, socket, head, (ws) => new PhoneSession(ws, publicBaseUrl(req)));
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
