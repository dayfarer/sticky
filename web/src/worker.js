// Sticky Notes sync server: a tiny API over a D1 table, live change pings over WebSockets
// (a Durable Object), and the phone web app (static assets).
//
// Every /api request needs the SYNC_KEY: as `Authorization: Bearer <key>`, or for the WebSocket
// from a browser, as a `key.<key>` subprotocol. The server owns all timestamps, so devices with
// wrong clocks can't break sync.
import { DurableObject } from "cloudflare:workers";

const MAX_BODY = 1_000_000;

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

function keyMatches(token, env) {
  if (!env.SYNC_KEY || !token) return false;
  const a = new TextEncoder().encode(token);
  const b = new TextEncoder().encode(env.SYNC_KEY);
  if (a.byteLength !== b.byteLength) return false;
  return crypto.subtle.timingSafeEqual(a, b);
}

function bearer(request) {
  const header = request.headers.get("authorization") || "";
  return header.startsWith("Bearer ") ? header.slice(7) : "";
}

function protocols(request) {
  return (request.headers.get("sec-websocket-protocol") || "").split(",").map((s) => s.trim()).filter(Boolean);
}

// Note IDs are file names like "note-1a2b3c4d.md". No folders, no hidden files.
function validId(id) {
  return typeof id === "string" && id.length <= 200 && id.endsWith(".md") &&
    !id.startsWith(".") && !/[\/\\\u0000]/.test(id);
}

// Each device sends a random client ID, so the server can tell "my own earlier save" from
// "another device's edit".
function cleanClient(c) {
  return typeof c === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(c) ? c : "";
}

const toNote = (row) => row && {
  id: row.id,
  body: row.body,
  updatedAt: row.updated_at,
  deleted: !!row.deleted,
  lastClient: row.last_client || "",
};

const publicNote = (n) => n && { id: n.id, body: n.body, updatedAt: n.updatedAt, deleted: n.deleted };

// Next timestamp: now, but always later than anything already stored (keeps `since` pulls exact).
const NEXT_TS = "MAX(?, (SELECT COALESCE(MAX(updated_at), 0) + 1 FROM notes))";

async function getNote(env, id) {
  return toNote(await env.DB.prepare("SELECT * FROM notes WHERE id = ?").bind(id).first());
}

async function writeNote(env, id, body, client) {
  const row = await env.DB.prepare(
    `INSERT INTO notes (id, body, updated_at, deleted, last_client) VALUES (?, ?, ${NEXT_TS}, 0, ?)
     ON CONFLICT(id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at,
       deleted = 0, last_client = excluded.last_client
     RETURNING *`
  ).bind(id, body, Date.now(), client).first();
  return toNote(row);
}

function conflictCopyId(id) {
  const stem = id.slice(0, -3);
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  const stamp = `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}-${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}`;
  return `${stem}-conflict-${stamp}.md`;
}

// Did another device change this note after the sender last saw it?
function changedElsewhere(existing, base, client) {
  if (!existing || existing.deleted) return false;
  const stale = base === null || existing.updatedAt > base;
  const sameDevice = client && existing.lastClient === client;
  return stale && !sameDevice;
}

function hub(env) {
  return env.HUB.get(env.HUB.idFromName("notes"));
}

// Tell every other connected device that something changed.
function notify(env, ctx, updatedAt, client) {
  ctx.waitUntil(
    hub(env).fetch("https://hub/notify", {
      method: "POST",
      body: JSON.stringify({ updatedAt, from: client }),
    }).catch(() => {})
  );
}

async function handleApi(request, env, ctx, url) {
  if (url.pathname === "/api/live") {
    if (request.headers.get("upgrade") !== "websocket") return json({ error: "expected a websocket" }, 426);
    const keyProto = protocols(request).find((p) => p.startsWith("key."));
    const ok = keyMatches(bearer(request), env) || (keyProto && keyMatches(keyProto.slice(4), env));
    if (!ok) return json({ error: "unauthorized" }, 401);
    return hub(env).fetch(request);
  }

  if (!keyMatches(bearer(request), env)) return json({ error: "unauthorized" }, 401);

  if (url.pathname === "/api/ping") return json({ ok: true });

  if (url.pathname === "/api/notes" && request.method === "GET") {
    const since = Number(url.searchParams.get("since") || 0) || 0;
    const { results } = await env.DB.prepare(
      "SELECT * FROM notes WHERE updated_at > ? ORDER BY updated_at"
    ).bind(since).all();
    return json({ notes: results.map((r) => publicNote(toNote(r))) });
  }

  const m = url.pathname.match(/^\/api\/notes\/(.+)$/);
  if (!m) return json({ error: "not found" }, 404);
  let id;
  try { id = decodeURIComponent(m[1]); } catch { return json({ error: "bad id" }, 400); }
  if (!validId(id)) return json({ error: "bad id" }, 400);

  if (request.method === "GET") {
    const note = await getNote(env, id);
    return note ? json({ note: publicNote(note) }) : json({ error: "not found" }, 404);
  }

  if (request.method === "PUT") {
    let input;
    try { input = await request.json(); } catch { return json({ error: "bad json" }, 400); }
    const body = typeof input.body === "string" ? input.body : null;
    if (body === null) return json({ error: "body must be a string" }, 400);
    if (body.length > MAX_BODY) return json({ error: "note too large" }, 413);
    const base = typeof input.base === "number" ? input.base : null;
    const client = cleanClient(input.client);

    const existing = await getNote(env, id);
    if (existing && !existing.deleted && existing.body === body) return json({ note: publicNote(existing) });

    // Another device changed this note since this device last saw it: keep theirs,
    // save this version as a separate copy so nothing is lost.
    if (changedElsewhere(existing, base, client)) {
      const copy = await writeNote(env, conflictCopyId(id), body, client);
      notify(env, ctx, copy.updatedAt, client);
      return json({ conflict: true, note: publicNote(existing), copy: publicNote(copy) }, 409);
    }
    const note = await writeNote(env, id, body, client);
    notify(env, ctx, note.updatedAt, client);
    return json({ note: publicNote(note) });
  }

  if (request.method === "DELETE") {
    const base = url.searchParams.has("base") ? Number(url.searchParams.get("base")) : null;
    const client = cleanClient(url.searchParams.get("client"));
    const existing = await getNote(env, id);
    if (!existing || existing.deleted) return json({ ok: true });
    // Edited on another device after this one last saw it: don't delete those edits.
    if (base !== null && changedElsewhere(existing, base, client)) {
      return json({ conflict: true, note: publicNote(existing) }, 409);
    }
    const row = await env.DB.prepare(
      `UPDATE notes SET body = '', deleted = 1, updated_at = ${NEXT_TS}, last_client = ? WHERE id = ? RETURNING *`
    ).bind(Date.now(), client, id).first();
    const note = toNote(row);
    notify(env, ctx, note.updatedAt, client);
    return json({ ok: true, note: publicNote(note) });
  }

  return json({ error: "method not allowed" }, 405);
}

// One Durable Object holds every device's live connection and pings them when notes change.
// Hibernation keeps idle connections free.
export class Hub extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/notify") {
      const { updatedAt, from } = await request.json();
      const msg = JSON.stringify({ type: "changed", updatedAt });
      for (const ws of this.ctx.getWebSockets()) {
        const info = ws.deserializeAttachment() || {};
        if (from && info.client === from) continue;
        try { ws.send(msg); } catch {}
      }
      return new Response("ok");
    }

    // WebSocket upgrade (the Worker already checked the key).
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ client: cleanClient(url.searchParams.get("client")) });
    const headers = protocols(request).includes("sticky") ? { "sec-websocket-protocol": "sticky" } : {};
    return new Response(null, { status: 101, webSocket: client, headers });
  }

  webSocketMessage() {}

  webSocketClose(ws, code) {
    try { ws.close(code, "closing"); } catch {}
  }
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/api/")) {
      try {
        return await handleApi(request, env, ctx, url);
      } catch (e) {
        return json({ error: "server error", detail: String((e && e.message) || e) }, 500);
      }
    }
    return env.ASSETS.fetch(request);
  },
};
