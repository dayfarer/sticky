// Sticky Notes for the phone: list, search, and a live-styled Markdown editor that syncs
// with Sticky on the Mac through the /api server.
import { EditorView, keymap, Decoration, ViewPlugin, WidgetType, drawSelection, placeholder } from "@codemirror/view";
import { EditorState, EditorSelection } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap, indentWithTab, undo } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { syntaxHighlighting, HighlightStyle } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";

// ---------- Local storage (offline cache) ----------

const store = {
  get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} },
};

let key = store.get("sticky.key", "");
let notes = store.get("sticky.notes", {});        // id -> { id, body, updatedAt, dirty, editedAt }
let deletes = store.get("sticky.deletes", []);    // [{ id, base }] waiting to reach the server
let lastPull = store.get("sticky.lastPull", 0);
let lastSynced = store.get("sticky.lastSynced", 0);

// A random ID for this device, so the server knows our own saves from other devices' edits.
let clientId = store.get("sticky.client", "");
if (!clientId) {
  clientId = "web-" + Array.from(crypto.getRandomValues(new Uint8Array(8)), (x) => x.toString(16).padStart(2, "0")).join("");
  store.set("sticky.client", clientId);
}

function persist() {
  store.set("sticky.notes", notes);
  store.set("sticky.deletes", deletes);
  store.set("sticky.lastPull", lastPull);
  store.set("sticky.lastSynced", lastSynced);
}

// ---------- Helpers ----------

const $ = (s) => document.querySelector(s);

function title(body) {
  const line = (body || "").split("\n").find((l) => l.trim());
  const tt = line ? line.replace(/^[\s#>*\-\[\]xX]+/, "").trim() : "";
  return tt || "New Note";
}

function snippet(body) {
  const lines = (body || "").split("\n").filter((l) => l.trim());
  return (lines[1] || "").replace(/^[\s#>*\-\[\]xX]+/, "").trim();
}

function ago(ms) {
  if (!ms) return "";
  const s = Math.round((Date.now() - ms) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  if (s < 86400 * 7) return `${Math.floor(s / 86400)}d ago`;
  return new Date(ms).toLocaleDateString();
}

const sortTime = (n) => Math.max(n.updatedAt || 0, n.editedAt || 0);

function newId() {
  const b = crypto.getRandomValues(new Uint8Array(4));
  return "note-" + Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("") + ".md";
}

let toastTimer;
function toast(msg) {
  const el = $("#toast");
  el.textContent = msg;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 3500);
}

function setStatus(text) { $("#status").textContent = text; }

function refreshStatus() {
  const pending = Object.values(notes).some((n) => n.dirty) || deletes.length;
  if (!navigator.onLine) setStatus(pending ? "Offline · changes will sync" : "Offline");
  else setStatus(pending ? "Syncing…" : lastSynced ? `Synced ${ago(lastSynced)}` : "");
}

// ---------- API ----------

async function api(path, opts = {}) {
  const res = await fetch(path, {
    ...opts,
    headers: { authorization: "Bearer " + key, "content-type": "application/json" },
  });
  if (res.status === 401) throw Object.assign(new Error("unauthorized"), { status: 401 });
  const data = await res.json().catch(() => ({}));
  return { status: res.status, data };
}

// ---------- Sync ----------

let syncing = false;
let syncAgain = false;
let pushTimer;

async function pushChanges() {
  for (const d of [...deletes]) {
    const q = `?client=${clientId}` + (d.base ? `&base=${d.base}` : "");
    const { status, data } = await api(`/api/notes/${encodeURIComponent(d.id)}${q}`, { method: "DELETE" });
    if (status === 409 && data.note) {
      notes[d.id] = { id: d.id, body: data.note.body, updatedAt: data.note.updatedAt };
      toast(`“${title(data.note.body)}” was edited on another device, so it wasn't deleted.`);
    } else if (status !== 200) throw new Error(data.error || status);
    deletes = deletes.filter((x) => x !== d);
    persist();
  }

  for (const n of Object.values(notes)) {
    if (!n.dirty || n.conflict) continue;  // a conflict waits for the person to choose
    if (!n.updatedAt && !n.body.trim()) continue;  // empty new note: nothing to save yet
    const sent = n.body;
    const { status, data } = await api(`/api/notes/${encodeURIComponent(n.id)}`, {
      method: "PUT",
      body: JSON.stringify({ body: sent, base: n.updatedAt || null, client: clientId, onConflict: "ask" }),
    });
    if (status === 200) {
      n.updatedAt = data.note.updatedAt;
      if (n.body === sent) n.dirty = false;
    } else if (status === 409) {
      // Changed on another device too: keep both versions locally and ask what to do.
      n.conflict = { body: data.note.body, updatedAt: data.note.updatedAt };
    } else {
      throw new Error(data.error || status);
    }
    persist();
  }
}

async function pull() {
  const { status, data } = await api(`/api/notes?since=${lastPull}`);
  if (status !== 200) throw new Error(data.error || status);
  for (const s of data.notes) {
    lastPull = Math.max(lastPull, s.updatedAt);
    const n = notes[s.id];
    if (n && n.conflict) {
      if (s.deleted) delete n.conflict;  // deleted elsewhere: our edit just brings it back
      else n.conflict = { body: s.body, updatedAt: s.updatedAt };
      continue;
    }
    if (n && n.dirty) continue;  // our pending edit goes first; the server reports any conflict
    if (s.deleted) {
      if (n) {
        delete notes[s.id];
        if (currentId === s.id) { closeEditor(); toast("That note was deleted on another device."); }
      }
      continue;
    }
    if (n && n.body === s.body) { n.updatedAt = s.updatedAt; continue; }
    notes[s.id] = { id: s.id, body: s.body, updatedAt: s.updatedAt };
    if (currentId === s.id) replaceDoc(s.body);
  }
  persist();
}

async function sync() {
  if (!key) return;
  if (syncing) { syncAgain = true; return; }
  syncing = true;
  try {
    await pushChanges();
    await pull();
    lastSynced = Date.now();
    persist();
  } catch (e) {
    if (e.status === 401) { showSetup("That key doesn't work anymore. Paste the current one."); }
  } finally {
    syncing = false;
    refreshStatus();
    renderList();
    if (syncAgain) { syncAgain = false; sync(); }
    askAboutConflicts();
  }
}

// ---------- Conflicts: ask, don't guess ----------

function preview(body) {
  const lines = (body || "").split("\n").filter((l) => l.trim()).slice(0, 4).join("\n");
  return lines.length > 220 ? lines.slice(0, 220) + "…" : lines || "(empty)";
}

let asking = false;

function askAboutConflicts() {
  if (asking || document.hidden) return;
  const n = Object.values(notes).find((x) => x.conflict);
  if (!n) return;
  asking = true;
  const dlg = $("#conflict");
  $("#conflict-title").textContent = `“${title(n.body)}” changed on another device`;
  $("#conflict-theirs").textContent = preview(n.conflict.body);
  $("#conflict-mine").textContent = preview(n.body);
  dlg.returnValue = "";
  dlg.onclose = async () => {
    asking = false;
    const choice = dlg.returnValue;
    if (choice) await resolveConflict(n.id, choice);
    setTimeout(askAboutConflicts, 300);
  };
  dlg.showModal();
}

async function resolveConflict(id, choice) {
  const n = notes[id];
  if (!n || !n.conflict) return;
  try {
    if (choice === "theirs") {
      n.body = n.conflict.body;
      n.updatedAt = n.conflict.updatedAt;
      n.dirty = false;
      delete n.conflict;
      if (currentId === id) replaceDoc(n.body);
    } else {
      const keepBoth = choice === "both";
      const { status, data } = await api(`/api/notes/${encodeURIComponent(id)}`, {
        method: "PUT",
        body: JSON.stringify({
          body: n.body,
          base: n.updatedAt || null,
          client: clientId,
          ...(keepBoth ? { onConflict: "copy" } : { force: true }),
        }),
      });
      if (status === 200) {
        n.updatedAt = data.note.updatedAt;
      } else if (status === 409 && data.copy) {
        // Keep both: the other device's version stays here, ours becomes a copy.
        notes[data.copy.id] = { id: data.copy.id, body: data.copy.body, updatedAt: data.copy.updatedAt };
        n.body = data.note.body;
        n.updatedAt = data.note.updatedAt;
        if (currentId === id) replaceDoc(n.body);
        toast("Kept both. Your version is saved as a copy.");
      } else {
        throw new Error(data.error || status);
      }
      n.dirty = false;
      delete n.conflict;
    }
    persist();
    renderList();
  } catch (e) {
    toast("Couldn't save your choice. It'll ask again.");
  }
  refreshStatus();
}

// ---------- Live updates ----------
// The server pings every other device right after a save, so changes show up in about a second.

let socket = null;
let socketRetry = 1000;
let socketTimer;

function connectLive() {
  if (!key || document.hidden || (socket && socket.readyState <= 1)) return;
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  const ws = new WebSocket(`${proto}//${location.host}/api/live?client=${clientId}`, ["sticky", "key." + key]);
  socket = ws;
  ws.onopen = () => { socketRetry = 1000; sync(); };
  ws.onmessage = (e) => { if (String(e.data).includes("changed")) sync(); };
  ws.onclose = () => {
    if (socket === ws) socket = null;
    clearTimeout(socketTimer);
    if (key && !document.hidden) socketTimer = setTimeout(connectLive, socketRetry);
    socketRetry = Math.min(socketRetry * 2, 30000);
  };
}

function disconnectLive() {
  clearTimeout(socketTimer);
  if (socket) { const ws = socket; socket = null; ws.close(); }
}

// Keep the connection from going idle on mobile networks.
setInterval(() => { if (socket && socket.readyState === 1) socket.send("ping"); }, 25000);

function schedulePush() {
  clearTimeout(pushTimer);
  pushTimer = setTimeout(sync, 400);
}

// ---------- Editor ----------

const mdStyle = HighlightStyle.define([
  { tag: t.heading1, fontSize: "1.55em", fontWeight: "700" },
  { tag: t.heading2, fontSize: "1.3em", fontWeight: "700" },
  { tag: t.heading3, fontSize: "1.12em", fontWeight: "700" },
  { tag: [t.heading4, t.heading5, t.heading6], fontWeight: "700" },
  { tag: t.strong, fontWeight: "700" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strikethrough, textDecoration: "line-through", color: "var(--muted)" },
  { tag: t.link, color: "var(--accent)" },
  { tag: t.url, color: "var(--faint)" },
  { tag: t.monospace, fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", fontSize: "0.88em", backgroundColor: "var(--code-bg)", borderRadius: "4px" },
  { tag: t.quote, color: "var(--muted)" },
  { tag: [t.processingInstruction, t.meta, t.contentSeparator], color: "var(--faint)" },
  { tag: t.atom, color: "var(--accent)" },
]);

const TASK = /^(\s*[-*+] )\[([ xX])\]/;

class BoxWidget extends WidgetType {
  constructor(checked) { super(); this.checked = checked; }
  eq(o) { return o.checked === this.checked; }
  toDOM() {
    const el = document.createElement("span");
    el.className = "cm-box" + (this.checked ? " on" : "");
    el.setAttribute("role", "checkbox");
    el.setAttribute("aria-checked", String(this.checked));
    return el;
  }
  ignoreEvent() { return false; }
}

function taskDecorations(view) {
  const ranges = [];
  for (const { from, to } of view.visibleRanges) {
    for (let pos = from; pos <= to;) {
      const line = view.state.doc.lineAt(pos);
      const m = TASK.exec(line.text);
      if (m) {
        const start = line.from + m[1].length;
        const checked = m[2] !== " ";
        ranges.push(Decoration.replace({ widget: new BoxWidget(checked) }).range(start, start + 3));
        if (checked && line.to > start + 3) ranges.push(Decoration.mark({ class: "cm-done" }).range(start + 3, line.to));
      }
      pos = line.to + 1;
    }
  }
  return Decoration.set(ranges, true);
}

function toggleTaskAt(view, pos) {
  const line = view.state.doc.lineAt(pos);
  const m = TASK.exec(line.text);
  if (!m) return false;
  const at = line.from + m[1].length + 1;
  view.dispatch({ changes: { from: at, to: at + 1, insert: m[2] === " " ? "x" : " " } });
  return true;
}

const taskBoxes = ViewPlugin.fromClass(class {
  constructor(view) { this.decorations = taskDecorations(view); }
  update(u) { if (u.docChanged || u.viewportChanged) this.decorations = taskDecorations(u.view); }
}, {
  decorations: (v) => v.decorations,
  eventHandlers: {
    mousedown(e, view) {
      const box = e.target.closest && e.target.closest(".cm-box");
      if (!box) return false;
      e.preventDefault();
      return toggleTaskAt(view, view.posAtDOM(box));
    },
  },
});

let currentId = null;
let applyingRemote = false;

function makeState(doc) {
  return EditorState.create({
    doc,
    extensions: [
      history(),
      drawSelection(),
      EditorView.lineWrapping,
      markdown({ base: markdownLanguage }),
      syntaxHighlighting(mdStyle),
      taskBoxes,
      keymap.of([...historyKeymap, ...defaultKeymap, indentWithTab]),
      placeholder("Start typing…"),
      EditorView.contentAttributes.of({ autocapitalize: "sentences", spellcheck: "true" }),
      EditorView.updateListener.of((u) => { if (u.docChanged && !applyingRemote) onEdit(u.state.doc.toString()); }),
    ],
  });
}

const view = new EditorView({ state: makeState(""), parent: $("#editor-host") });

function onEdit(body) {
  const n = notes[currentId];
  if (!n || n.body === body) return;
  n.body = body;
  n.dirty = true;
  n.editedAt = Date.now();
  persist();
  setStatus("Saving…");
  schedulePush();
}

function replaceDoc(body) {
  if (view.state.doc.toString() === body) return;
  const head = Math.min(view.state.selection.main.head, body.length);
  applyingRemote = true;
  view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: body }, selection: { anchor: head } });
  applyingRemote = false;
}

// ---------- Formatting toolbar ----------

function wrap(open, close = open) {
  const s = view.state;
  view.dispatch(s.changeByRange((r) => {
    const before = s.sliceDoc(r.from - open.length, r.from);
    const after = s.sliceDoc(r.to, r.to + close.length);
    if (before === open && after === close) {
      return {
        changes: [{ from: r.from - open.length, to: r.from }, { from: r.to, to: r.to + close.length }],
        range: EditorSelection.range(r.from - open.length, r.to - open.length),
      };
    }
    return {
      changes: [{ from: r.from, insert: open }, { from: r.to, insert: close }],
      range: EditorSelection.range(r.from + open.length, r.to + open.length),
    };
  }));
}

const PREFIX = /^(\s*)(#{1,6} |[-*+] \[[ xX]\] |[-*+] |\d+[.)] |> )?/;
const MARKERS = { h1: "# ", h2: "## ", h3: "### ", bullet: "- ", task: "- [ ] ", quote: "> ", ordered: "1. " };

function kindOf(prefix) {
  if (!prefix) return null;
  if (prefix.startsWith("#")) return "h" + (prefix.trim().length);
  if (prefix.includes("[")) return "task";
  if (prefix.startsWith(">")) return "quote";
  if (/^\d/.test(prefix)) return "ordered";
  return "bullet";
}

function setLineKind(kind) {
  const s = view.state;
  const lines = new Map();
  for (const r of s.selection.ranges) {
    for (let l = s.doc.lineAt(r.from).number; l <= s.doc.lineAt(r.to).number; l++) lines.set(l, s.doc.line(l));
  }
  const list = [...lines.values()];
  const kinds = list.map((line) => kindOf(PREFIX.exec(line.text)[2]));
  const turnOff = kinds.every((k) => k === kind);
  let n = 0;
  const changes = list.map((line) => {
    const m = PREFIX.exec(line.text);
    const from = line.from + m[1].length;
    const to = from + (m[2] ? m[2].length : 0);
    if (turnOff) return { from, to, insert: "" };
    n += 1;
    return { from, to, insert: kind === "ordered" ? `${n}. ` : MARKERS[kind] };
  });
  // Map the cursor forward, so it lands after an inserted marker, not before it.
  const set = s.changes(changes);
  view.dispatch({ changes: set, selection: s.selection.map(set, 1) });
}

function cycleHeading() {
  const line = view.state.doc.lineAt(view.state.selection.main.head);
  const k = kindOf(PREFIX.exec(line.text)[2]);
  const next = { h1: "h2", h2: "h3", h3: "h1" }[k] || "h1";
  if (k === "h3") { setLineKind("h3"); return; }  // h3 → plain text
  setLineKind(next);
}

function toggleTaskLine() {
  const pos = view.state.selection.main.head;
  if (!toggleTaskAt(view, pos)) setLineKind("task");
}

const actions = {
  heading: cycleHeading,
  bold: () => wrap("**"),
  italic: () => wrap("*"),
  strike: () => wrap("~~"),
  code: () => wrap("`"),
  task: () => setLineKind("task"),
  check: toggleTaskLine,
  bullet: () => setLineKind("bullet"),
  ordered: () => setLineKind("ordered"),
  quote: () => setLineKind("quote"),
  undo: () => undo(view),
};

for (const btn of document.querySelectorAll("[data-fmt]")) {
  // pointerdown + preventDefault keeps the keyboard open.
  btn.addEventListener("pointerdown", (e) => {
    e.preventDefault();
    actions[btn.dataset.fmt]?.();
    view.focus();
  });
}

// Keep the toolbar right above the on-screen keyboard.
function placeToolbar() {
  const vv = window.visualViewport;
  if (!vv) return;
  const hidden = Math.max(0, window.innerHeight - (vv.height + vv.offsetTop));
  $("#toolbar").style.transform = `translateY(${-hidden}px)`;
}
window.visualViewport?.addEventListener("resize", placeToolbar);
window.visualViewport?.addEventListener("scroll", placeToolbar);

// ---------- Screens ----------

function show(screen) {
  for (const s of ["setup", "list", "editor"]) $(`#${s}`).hidden = s !== screen;
  document.body.dataset.screen = screen;
}

function renderList() {
  const q = $("#search").value.trim().toLowerCase();
  const tokens = q.split(/\s+/).filter(Boolean);
  const items = Object.values(notes)
    .filter((n) => n.body.trim() || n.id === currentId)
    .filter((n) => tokens.every((tk) => n.body.toLowerCase().includes(tk)))
    .sort((a, b) => sortTime(b) - sortTime(a));

  const ul = $("#notes");
  ul.replaceChildren();
  for (const n of items) {
    const li = document.createElement("li");
    const btn = document.createElement("button");
    btn.className = "note-row";
    const top = document.createElement("div");
    top.className = "row-top";
    const h = document.createElement("span");
    h.className = "row-title";
    h.textContent = title(n.body);
    const time = document.createElement("span");
    time.className = "row-time";
    time.textContent = n.dirty ? "unsynced" : ago(sortTime(n));
    top.append(h, time);
    const p = document.createElement("div");
    p.className = "row-snippet";
    p.textContent = snippet(n.body) || " ";
    btn.append(top, p);
    btn.addEventListener("click", () => openNote(n.id));
    li.append(btn);
    ul.append(li);
  }
  $("#empty").hidden = items.length > 0;
  $("#empty").textContent = tokens.length ? "No notes match." : "No notes yet. Tap + to write one.";
}

function openNote(id, focus = false) {
  currentId = id;
  view.setState(makeState(notes[id].body));
  show("editor");
  if (focus) view.focus();
  else view.scrollDOM.scrollTop = 0;
}

function closeEditor() {
  const n = notes[currentId];
  if (n && !n.updatedAt && !n.body.trim()) delete notes[currentId];  // discard empty new note
  currentId = null;
  view.contentDOM.blur();
  persist();
  renderList();
  show("list");
  sync();
}

function newNote() {
  const id = newId();
  notes[id] = { id, body: "", updatedAt: 0 };
  openNote(id, true);
}

function deleteNote() {
  const n = notes[currentId];
  if (!n) return;
  if (!confirm(`Delete “${title(n.body)}”? On your Mac it goes to the Trash.`)) return;
  if (n.updatedAt) deletes.push({ id: n.id, base: n.updatedAt });
  delete notes[currentId];
  currentId = null;
  persist();
  renderList();
  show("list");
  sync();
}

async function copyNote() {
  const n = notes[currentId];
  if (!n) return;
  try { await navigator.clipboard.writeText(n.body); toast("Copied as Markdown."); } catch { toast("Couldn't copy."); }
}

function showSetup(message) {
  $("#setup-msg").textContent = message || "";
  show("setup");
}

async function connect() {
  const value = $("#key-input").value.trim();
  if (!value) return;
  $("#connect").disabled = true;
  const prev = key;
  key = value;
  try {
    const { status } = await api("/api/ping");
    if (status !== 200) throw new Error();
    store.set("sticky.key", key);
    $("#key-input").value = "";
    show("list");
    await sync();
    connectLive();
  } catch (e) {
    key = prev;
    $("#setup-msg").textContent = e.status === 401 ? "That key didn't work. Check you copied all of it." : "Couldn't reach the server. Check your connection.";
  } finally {
    $("#connect").disabled = false;
  }
}

// ---------- Wire up ----------

$("#new").addEventListener("click", newNote);
$("#back").addEventListener("click", closeEditor);
$("#delete").addEventListener("click", deleteNote);
$("#copy").addEventListener("click", copyNote);
$("#search").addEventListener("input", renderList);
$("#connect").addEventListener("click", connect);
$("#key-input").addEventListener("keydown", (e) => { if (e.key === "Enter") connect(); });
$("#signout").addEventListener("click", () => {
  if (!confirm("Remove the sync key from this phone? Your notes stay on the server.")) return;
  key = "";
  store.set("sticky.key", "");
  disconnectLive();
  showSetup();
});

document.addEventListener("visibilitychange", () => {
  if (!document.hidden) { sync(); connectLive(); }
  else { persist(); disconnectLive(); }
});
window.addEventListener("online", () => { sync(); connectLive(); });
window.addEventListener("offline", refreshStatus);
setInterval(() => { if (!document.hidden) sync(); }, 60000);  // fallback if the live connection drops
setInterval(refreshStatus, 30000);

if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});

if (key) {
  show("list");
  renderList();
  refreshStatus();
  sync();
  connectLive();
} else {
  showSetup();
}
