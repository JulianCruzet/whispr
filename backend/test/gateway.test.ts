// Tests for the audio gateway: loudness, me/them labels, the bridge to the brain,
// and whispers never overlapping. A fake brain and a fake phone socket stand in for
// the real ones, and ElevenLabs runs in mock mode (TTS plays a short chime).
//
//   cd backend && npm test

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, test } from "node:test";
import { WebSocketServer, type WebSocket as ServerSocket } from "ws";

// Must be set before the gateway's config loads (dotenv never overrides set variables).
process.env.ELEVENLABS_API_KEY = "";
process.env.APP_SHARED_TOKEN = "";

/** Stands in for the brain: records what it receives and replies with the given events. */
class FakeBrain {
  readonly received: Record<string, unknown>[] = [];
  reply: (msg: Record<string, unknown>) => Record<string, unknown>[] = () => [];
  private server!: WebSocketServer;
  private sockets = new Set<ServerSocket>();

  async start(): Promise<string> {
    this.server = new WebSocketServer({ port: 0 });
    this.server.on("connection", (ws) => {
      this.sockets.add(ws);
      ws.on("message", (data) => {
        const msg = JSON.parse(data.toString());
        this.received.push(msg);
        for (const event of this.reply(msg)) ws.send(JSON.stringify(event));
      });
    });
    await new Promise((resolve) => this.server.once("listening", resolve));
    return `ws://localhost:${(this.server.address() as AddressInfo).port}/ws`;
  }

  async stop() {
    for (const ws of this.sockets) ws.terminate();
    await new Promise((resolve) => this.server.close(resolve));
  }
}

/** Stands in for the phone's WebSocket as PhoneSession sees it. */
class FakePhone extends EventEmitter {
  readonly OPEN = 1;
  readyState = 1;
  /** JSON events and, as "<audio N bytes>", binary whisper audio, in order. */
  readonly log: (Record<string, any> | string)[] = [];

  send(data: string | Buffer, opts?: { binary?: boolean }) {
    this.log.push(opts?.binary ? `<audio ${(data as Buffer).length} bytes>` : JSON.parse(data as string));
  }

  say(msg: Record<string, unknown>) {
    this.emit("message", Buffer.from(JSON.stringify(msg)), false);
  }

  events(type: string) {
    return this.log.filter((e): e is Record<string, any> => typeof e !== "string" && e.type === type);
  }
}

async function until(check: () => boolean, ms = 3000) {
  const start = Date.now();
  while (!check()) {
    if (Date.now() - start > ms) throw new Error("timed out waiting");
    await new Promise((r) => setTimeout(r, 10));
  }
}

/** Stands in for an image host: /photo.jpg is an image (after ?delay= ms), anything else 404s. */
const PHOTO = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
let imageHost: Server;
let imageBase = "";

const brain = new FakeBrain();
let PhoneSession: typeof import("../src/session.js").PhoneSession;
let levelDb: typeof import("../src/ears/scribe.js").levelDb;
let getImage: typeof import("../src/media.js").getImage;

before(async () => {
  imageHost = createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://x");
    if (url.pathname !== "/photo.jpg") return void res.writeHead(404).end();
    setTimeout(() => res.writeHead(200, { "Content-Type": "image/jpeg" }).end(PHOTO), Number(url.searchParams.get("delay") ?? 0));
  });
  await new Promise<void>((resolve) => imageHost.listen(0, resolve));
  imageBase = `http://localhost:${(imageHost.address() as AddressInfo).port}`;

  process.env.BRAIN_URL = await brain.start();
  ({ PhoneSession } = await import("../src/session.js"));
  ({ levelDb } = await import("../src/ears/scribe.js"));
  ({ getImage } = await import("../src/media.js"));
});

const phones: FakePhone[] = [];

after(async () => {
  // Hanging up closes each session's brain link, so nothing keeps the process alive.
  for (const phone of phones) phone.emit("close");
  await brain.stop();
  await new Promise((resolve) => imageHost.close(resolve));
});

function newSession() {
  const phone = new FakePhone();
  phones.push(phone);
  const session = new PhoneSession(phone as never);
  // Test hook: what Scribe would emit for a finished line at a given loudness.
  // Test hook: what Scribe would emit for a finished line at a given loudness (no audio, so
  // speaker detection falls back to loudness; speakers.test.ts covers voices).
  const scribeSays = (text: string, db: number | null) =>
    (session as any).scribe.emit("committed", text, { levelDb: db, words: [{ text, start: 0, end: 1 }] });
  return { phone, session, scribeSays };
}

describe("loudness", () => {
  test("silence is the floor and a full-scale tone is near 0 dBFS", () => {
    assert.equal(levelDb(Buffer.alloc(3200)), -90);
    const tone = Buffer.alloc(3200);
    for (let i = 0; i < 1600; i++) tone.writeInt16LE(Math.round(Math.sin(i / 3) * 32767), i * 2);
    assert.ok(Math.abs(levelDb(tone) - -3) < 0.5, `got ${levelDb(tone)}`);
  });
});

describe("me vs them", () => {
  test("before calibrating, lines are unknown and the brain gets no speaker", async () => {
    brain.received.length = 0;
    const { phone, scribeSays } = newSession();
    scribeSays("hello there", -20);
    await until(() => brain.received.length === 1);
    assert.equal(phone.events("transcript")[0].speaker, "unknown");
    assert.equal(brain.received[0].speaker, null);
    assert.equal(brain.received[0].is_final, true);
  });

  test("calibrating labels the wearer's line and splits later lines by loudness", async () => {
    brain.received.length = 0;
    const { phone, scribeSays } = newSession();
    phone.say({ type: "calibrate" });
    scribeSays("hey I'm Julian", -21);
    scribeSays("you saw Drake live?", -31); // 10 dB quieter: the other person
    scribeSays("yeah it was great", -24); // within 8 dB: the wearer
    await until(() => brain.received.length === 3);

    assert.deepEqual(phone.events("calibrated")[0], { type: "calibrated", who: "me", ok: true });
    assert.deepEqual(
      brain.received.map((m) => m.speaker),
      ["me", "them", "me"],
    );
  });

  test("calibrating on a line with no loudness reports failure", async () => {
    const { phone, scribeSays } = newSession();
    phone.say({ type: "calibrate" });
    scribeSays("hey", null);
    await until(() => phone.events("calibrated").length === 1);
    assert.equal(phone.events("calibrated")[0].ok, false);
  });
});

describe("bridge to the brain", () => {
  test("the brain's who-spoke verdict relabels an unknown line, keeping its id", async () => {
    brain.reply = (msg) => [{ type: "transcript", text: msg.text, who_spoke: "them", cover_blown_risk: 0.4 }];
    const { phone, scribeSays } = newSession();
    scribeSays("wait, you saw her live?", -25);
    await until(() => phone.events("transcript").length === 2);

    const [first, relabel] = phone.events("transcript");
    assert.equal(first.speaker, "unknown");
    assert.equal(relabel.speaker, "them");
    assert.equal(relabel.id, first.id);
    assert.deepEqual(phone.events("risk")[0], { type: "risk", score: 0.4 });
  });

  test("a whisper is shown and spoken; photo tasks map to phone events", async () => {
    brain.reply = () => [
      { type: "whisper", id: "w1", text: "Say the Toronto show.", reason: "reply", cover_blown_risk: 0.2 },
      { type: "task_started", task_id: "t1", task: "find_photo" },
      {
        type: "task_done",
        task_id: "t1",
        task: "find_photo",
        ok: true,
        image_url: `${imageBase}/missing.jpg`,
        title: "Scotiabank Arena",
        query: "q",
        used_fallback: false,
      },
    ];
    const { phone } = newSession();
    phone.say({ type: "debug_turn", text: "which show?", speaker: "them" });
    await until(() => phone.events("whisper_audio_end").length === 1 && phone.events("task_done").length === 1);

    assert.deepEqual(phone.events("whisper")[0], { type: "whisper", id: "w1", text: "Say the Toronto show." });
    assert.equal(phone.events("task_started")[0].id, "t1");
    assert.deepEqual(phone.events("task_done")[0], {
      type: "task_done",
      id: "t1",
      kind: "find_photo",
      ok: true,
      // The relay couldn't fetch it, so the phone gets the original address to try itself.
      imageUrl: `${imageBase}/missing.jpg`,
      caption: "Scotiabank Arena",
    });
    assert.ok(phone.log.some((e) => typeof e === "string" && e.startsWith("<audio")));
  });

  test("back-to-back whispers are spoken one after the other, never interleaved", async () => {
    brain.reply = () => [
      { type: "whisper", id: "a", text: "first", reason: "reply", cover_blown_risk: null },
      { type: "whisper", id: "b", text: "second", reason: "task_done", cover_blown_risk: null },
    ];
    const { phone } = newSession();
    phone.say({ type: "debug_turn", text: "go", speaker: "them" });
    await until(() => phone.events("whisper_audio_end").length === 2);

    const audioEvents = phone.log
      .map((e) => (typeof e === "string" ? "audio" : e.type.startsWith("whisper_audio") ? `${e.type}:${e.id}` : null))
      .filter(Boolean);
    assert.deepEqual(audioEvents, [
      "whisper_audio_start:a",
      "audio",
      "whisper_audio_end:a",
      "whisper_audio_start:b",
      "audio",
      "whisper_audio_end:b",
    ]);
  });
});

describe("photo relay", () => {
  const photoDone = (imageUrl: string) => ({
    type: "task_done",
    task_id: "t1",
    task: "find_photo",
    ok: true,
    image_url: imageUrl,
    title: "Drake at Scotiabank Arena",
  });

  test("the phone gets the photo from the gateway's /media, not the original host", async () => {
    brain.reply = () => [photoDone(`${imageBase}/photo.jpg`)];
    const phone = new FakePhone();
    phones.push(phone);
    new PhoneSession(phone as never, "https://whispr.example");
    phone.say({ type: "debug_turn", text: "I went to Drake's concert last night", speaker: "me" });
    await until(() => phone.events("task_done").length === 1);

    const { imageUrl } = phone.events("task_done")[0];
    const match = /^https:\/\/whispr\.example\/media\/([0-9a-f-]{36})$/.exec(imageUrl);
    assert.ok(match, `unexpected imageUrl ${imageUrl}`);
    const image = getImage(match[1]);
    assert.equal(image?.contentType, "image/jpeg");
    assert.deepEqual(image?.body, PHOTO);
  });

  test("the photo-ready whisper never overtakes a photo that's still downloading", async () => {
    brain.reply = () => [
      photoDone(`${imageBase}/photo.jpg?delay=300`),
      { type: "whisper", id: "ready", text: "Photo's on your phone.", reason: "task_done", cover_blown_risk: null },
    ];
    const { phone } = newSession();
    phone.say({ type: "debug_turn", text: "prove it", speaker: "them" });
    await until(() => phone.events("whisper").length === 1);

    const order = phone.log.filter((e) => typeof e !== "string" && ["task_done", "whisper"].includes(e.type));
    assert.deepEqual(
      order.map((e) => (e as Record<string, any>).type),
      ["task_done", "whisper"],
    );
  });
});

describe("calibrating the other person", () => {
  test("calibrate who=them marks that line as theirs and confirms it", async () => {
    brain.received.length = 0;
    brain.reply = () => [];
    const { phone, scribeSays } = newSession();
    phone.say({ type: "calibrate", who: "them" });
    scribeSays("hi, I'm Sam", -24);
    await until(() => phone.events("calibrated").length === 1 && brain.received.length === 1);

    // No audio here, so no voiceprint: a sample of the other person can't be taken.
    assert.deepEqual(phone.events("calibrated")[0], { type: "calibrated", who: "them", ok: false });
    assert.equal(phone.events("transcript")[0].speaker, "them");
    assert.equal(brain.received[0].speaker, "them");
  });
});

