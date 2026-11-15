// Sticky Notes sync server: a tiny API over a D1 table, plus the phone web app (static assets).
//
// Every /api request needs `Authorization: Bearer <SYNC_KEY>`. The server owns all timestamps,
// so devices with wrong clocks can't break sync.

const MAX_BODY = 1_000_000;

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

async function authorized(request, env) {
  const header = request.headers.get("authorization") || "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!env.SYNC_KEY || !token) return false;
  const a = new TextEncoder().encode(token);
  const b = new TextEncoder().encode(env.SYNC_KEY);
  if (a.byteLength !== b.byteLength) return false;
  return crypto.subtle.timingSafeEqual(a, b);
}

// Note IDs are file names like "note-1a2b3c4d.md". No folders, no hidden files.
function validId(id) {
  return typeof id === "string" && id.length <= 200 && id.endsWith(".md") &&
    !id.startsWith(".") && !/[\/\\\u0000]/.test(id);
}

const toNote = (row) => row && {
  id: row.id,
  body: row.body,
  updatedAt: row.updated_at,
  deleted: !!row.deleted,
};

// Next timestamp: now, but always later than anything already stored (keeps `since` pulls exact).
const NEXT_TS = "MAX(?, (SELECT COALESCE(MAX(updated_at), 0) + 1 FROM notes))";

async function getNote(env, id) {
  return toNote(await env.DB.prepare("SELECT * FROM notes WHERE id = ?").bind(id).first());
}

async function writeNote(env, id, body) {
  const row = await env.DB.prepare(
    `INSERT INTO notes (id, body, updated_at, deleted) VALUES (?, ?, ${NEXT_TS}, 0)
     ON CONFLICT(id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at, deleted = 0
     RETURNING *`
  ).bind(id, body, Date.now()).first();
  return toNote(row);
}

function conflictCopyId(id) {
  const stem = id.slice(0, -3);
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  const stamp = `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}-${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}`;
  return `${stem}-conflict-${stamp}.md`;
}

async function handleApi(request, env, url) {
  if (!(await authorized(request, env))) return json({ error: "unauthorized" }, 401);

  if (url.pathname === "/api/ping") return json({ ok: true });

  if (url.pathname === "/api/notes" && request.method === "GET") {
    const since = Number(url.searchParams.get("since") || 0) || 0;
    const { results } = await env.DB.prepare(
      "SELECT * FROM notes WHERE updated_at > ? ORDER BY updated_at"
    ).bind(since).all();
    return json({ notes: results.map(toNote) });
  }

  const m = url.pathname.match(/^\/api\/notes\/(.+)$/);
  if (!m) return json({ error: "not found" }, 404);
  let id;
  try { id = decodeURIComponent(m[1]); } catch { return json({ error: "bad id" }, 400); }
  if (!validId(id)) return json({ error: "bad id" }, 400);

  if (request.method === "GET") {
    const note = await getNote(env, id);
    return note ? json({ note }) : json({ error: "not found" }, 404);
  }

  if (request.method === "PUT") {
    let input;
    try { input = await request.json(); } catch { return json({ error: "bad json" }, 400); }
    const body = typeof input.body === "string" ? input.body : null;
    if (body === null) return json({ error: "body must be a string" }, 400);
    if (body.length > MAX_BODY) return json({ error: "note too large" }, 413);
    const base = typeof input.base === "number" ? input.base : null;

    const existing = await getNote(env, id);
    if (existing && !existing.deleted && existing.body === body) return json({ note: existing });

    // Someone else changed this note since this device last saw it: keep theirs,
    // save this version as a separate copy so nothing is lost.
    if (existing && !existing.deleted && (base === null || existing.updatedAt > base)) {
      const copy = await writeNote(env, conflictCopyId(id), body);
      return json({ conflict: true, note: existing, copy }, 409);
    }
    return json({ note: await writeNote(env, id, body) });
  }

  if (request.method === "DELETE") {
    const base = url.searchParams.has("base") ? Number(url.searchParams.get("base")) : null;
    const existing = await getNote(env, id);
    if (!existing || existing.deleted) return json({ ok: true });
    // Edited elsewhere after this device last saw it: don't delete those edits.
    if (base !== null && existing.updatedAt > base) return json({ conflict: true, note: existing }, 409);
    const row = await env.DB.prepare(
      `UPDATE notes SET body = '', deleted = 1, updated_at = ${NEXT_TS} WHERE id = ? RETURNING *`
    ).bind(Date.now(), id).first();
    return json({ ok: true, note: toNote(row) });
  }

  return json({ error: "method not allowed" }, 405);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/api/")) {
      try {
        return await handleApi(request, env, url);
      } catch (e) {
        return json({ error: "server error", detail: String(e && e.message || e) }, 500);
      }
    }
    return env.ASSETS.fetch(request);
  },
};
