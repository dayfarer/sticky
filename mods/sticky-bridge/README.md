# sticky-bridge

A Claude Code mod that lets the Sticky app send a message into a Claude chat that is open in the Claude app (or in a terminal). The message runs as your own turn, in the same chat, without bringing the app forward.

Sticky installs and removes this mod for you: menu bar → **Sync with Claude App**. You do not install it by hand.

## What it does

- In each Claude chat process it runs in, it writes a small "lease" file every 3 seconds. The lease tells Sticky that the chat is live, and whether a turn is running (and its id).
- It checks Sticky's outbox folder for this chat twice a second. When Sticky drops a message there, the mod submits it as your own turn (`$.prompt.submit` with `asUser: true`), once the running turn (if any) has ended. A "stop" message names a turn and stops it if it is still running (`$.turn.abort`); it never stops a later one.
- It writes an ack file for each message: `ok: true` when the turn started, or `ok: false` with the reason.

## What it reads and writes

Only files inside the bridge folder: `~/Library/Application Support/Sticky/bridge/` (or `STICKY_BRIDGE_DIR`, for tests).

| File | Who writes it |
| --- | --- |
| `leases/<sessionId>.json` | the mod |
| `outbox/<sessionId>/<id>.json` | Sticky |
| `outbox/<sessionId>/<id>.json.<loadId>.taken` | the mod (its claim) |
| `acks/<id>.json` | the mod |
| `log.txt` | the mod: ids, states and errors, never message text |

Limits it keeps:

- It acts only on files in Sticky's outbox for its own chat. It never reads your chats or any other file.
- It never creates a folder. Sticky makes the bridge folder and the folders in it; until then, the mod writes nothing.
- It refuses links. It reads at most 1 MiB per file. A message older than 8 seconds is refused and never sent.
- Sticky takes a message back by deleting its file (a Stop takes back every message that hasn't started). A message whose file is gone when its turn comes is never sent: the mod acks it `ok: false`.
- It makes no network calls, starts no processes and calls no MCP tools.
- It acts only in chats you run: the Claude app's own chat process (`CLAUDE_CODE_ENTRYPOINT=claude-desktop`) or an interactive terminal `claude` (`cli`). A `claude` that a chat's tools start (a script's `claude -p`, say) inherits that entrypoint, but Claude Code marks it (`CLAUDE_CODE_CHILD_SESSION`), and the mod does nothing there. In Sticky's own `claude -p` processes it does nothing.

## Turning it off

Sticky menu bar → turn off **Sync with Claude App**. Sticky then runs:

```
claude plugin uninstall sticky-bridge@sticky-local --scope user
claude plugin marketplace remove sticky-local
```

A chat whose process is already running keeps the mod until that process ends.

## Limits

- Images can't go through the bridge.
- Permission prompts for a turn sent from Sticky show in the Claude app.
- A chat whose claude process started before sync was turned on does not have the mod. It gets the mod when that process ends and a new one starts. The Claude app can keep a chat's process alive for minutes or days.
