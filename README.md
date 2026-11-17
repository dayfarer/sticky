# Sticky

Floating, always-on-top windows for macOS. Each sticky runs a terminal command, a website, a note or a Claude Code chat, and stays visible over every app — fullscreen apps too, on every desktop.

## What it does

- **Claude Code (web) sticky** — opens `claude.ai/code` in a floating window. Turn on Remote Control in the Claude desktop app to drive sessions on your Mac from it.
- **Claude CLI sticky** — runs `claude` in a folder you pick.
- **Claude chat sticky** — press **⌘O** in any sticky (or menu bar → **Open Claude Chat…**) to search every Claude Code chat on this Mac, newest first: ones from the terminal, the Claude app and Sticky (the earlier parts of a long Claude app chat show as rows of their own). Pick one and it opens in a clean chat view on top of the sticky's stack (if a sticky already shows it, that one comes up), and you can keep going right there. Claude only starts when you send. It asks before it runs a tool (Allow, Deny, or allow it for the rest of the chat, which Sticky keeps while the sticky is open), shows questions and plans as cards, and keeps working while the sticky is hidden. The footer picks the permission mode (Ask first, Accept edits, Plan, Auto) and the model, and shows what the chat cost. Esc stops a reply. Menu bar → **New Claude Chat…** starts one in a folder you pick.
- **Terminal sticky** — runs any command (`python3`, `htop`, `npm run dev`, …). When it exits you get a normal shell.
- **Web sticky** — any website. Sign-ins are saved. ⌘- / ⌘= / ⌘0 zoom the page (or pinch), and each sticky remembers its zoom.
- **Sticky switcher** — hold **⌃** and press **Tab** in any sticky (or **⌥Tab** from any app) to see all your web and terminal stickies with a picture of each, hidden ones too. **Let go** and the one you picked goes on top of the current sticky's stack (see below), like tabs in one window. **Return** opens it as its own window instead. A quick tap swaps back to the last one.
- **Stacks** — stickies can share one spot, like tabs: one shows, the rest wait behind it (still running). ⌃Tab (let go) puts a sticky on top. A link that opens a new tab (or a ⌘-click) opens on top of the stack too. **⌘W** takes just the top one off and shows the one under it. Move or resize the stack and they all come along. Sign-in popups ("Sign in with Google") open as their own small sticky and go away when you're done.
- **Note stickies** — press **⇧⌘N** in a note (or menu bar → **New Note Sticky**) to keep that note out as its own small sticky, like a to-do list next to Claude Code. It's the same editor with the same shortcuts, and it joins ⌃Tab, the menu bar list and ⌃⌥Space like any sticky. The notes window (⌃⌘B) stays separate. If a note is open in both, edits show up in the other right away.
- **Hide, don't close** — the red button and ⌘W hide a sticky (in a stack, only the top one). It keeps running (the terminal keeps its program, the page stays loaded) and comes back from the switcher or the menu bar. **⇧⌘W** closes it for good, and asks first if a program is still running.
- **Saved sites** — ⌘T (or menu bar → **New Web Sticky…**) opens a list of your saved sites and the sites you've opened before, so you don't retype addresses. ⌘D saves the page you're on. The list is ranked by relevance, not just recency: what you typed, how often and how lately you open a site, and what you picked before for the same text. A site counts as a visit once you've stayed 3 seconds, so sign-in pages you pass through don't clutter it.
- **Notes** — works like Raycast Notes. **⌃⌘B** shows or hides the notes window, which shows one note at a time. Markdown formats as you type: headings, **bold**, *italic*, underline, ~~strike~~, `code`, code blocks, quotes, links, and clickable `- [ ]` checklists. Return starts a new paragraph (or list item), Shift+Return adds a line break in the same paragraph, Tab indents lists. Notes autosave as plain `.md` files in `~/Documents/Sticky Notes`.
- **Math in notes** — math formats as you type, in the notes window and note stickies: `x^2`, `x^(n+1)` and `e^{-x}` become superscripts, `x_1` and `a_n` subscripts, `sqrt(2x+1)` and `cbrt(27)` get a √ with a bar over them, `1/2` becomes a small fraction, and `<=` `>=` `!=` `+-` `~=` `2*3` `pi` `theta` `inf` `90deg` become ≤ ≥ ≠ ± ≈ × π θ ∞ °. It's display only: the `.md` file (and the phone app) keeps exactly what you typed. Put the cursor on a piece of math to see and edit what you typed. Code, links and words like `snake_case` are left alone, and only one-digit fractions format, so dates like `11/16` stay as typed. Turn it off with menu bar → **Math Formatting** (saved in `~/Library/Application Support/Sticky/notes-state.json`).
- Fades to 40% when the mouse leaves and the window isn't focused.
- Notes and stickies stay separate. **⌃⌘B** only shows or hides the notes window, and **⌃⌥Space** only shows or hides the terminal and web stickies. Neither shortcut touches the other (no Accessibility permission needed).
- Remembers each sticky's position and reopens them on launch. The notes window stays hidden at launch until you press ⌃⌘B, and closing it only hides it, so it comes back in the same spot.
- Optional **Open at Login** toggle in the menu.
- Lives in the menu bar, no Dock icon.

## Sync with the Claude app

Menu bar → **Sync with Claude App** lets chat stickies and the Claude desktop app share chats. It's off until you turn it on, and it all stays on this Mac: no Remote Control, no cloud.

- **Send into the app's chat:** when the Claude app has a chat open, a message you send from its sticky runs there, as your own message in the same chat. The app stays in the background. The reply shows in the sticky as the app writes it to the chat's file, and Stop (Esc) stops it. Messages you sent that haven't started yet come back to the box when you press Stop.
- **New chats move to the app,** so they're in its sidebar. The first message runs in Sticky as usual, with the mode and model you picked. A few seconds after the reply, Sticky hands the chat to the app with Claude Code's own `claude --desktop --resume`: same chat, same id, no folder question and nothing to press. The app opens it (it shows that chat once, in the background), and from then on the sticky's messages go to it. If the app comes forward, the sticky comes back on top.
- **A rewind or /clear in the app** starts a new part of the chat. When the app has that part open, the sticky follows it. Otherwise the sticky asks: **Open in Claude**, or **Send here anyway** (into the part before).
- **Chats nothing has open** run in Sticky's own `claude`, which quits a few seconds after each reply. That way the chat's file always says where the chat ends, so the app (or a terminal) carries on from there. A `claude` that runs a background task (a dev server, say) stays until the task ends. If another Claude adds to the chat meanwhile, Sticky asks before it restarts its `claude`, because that ends the task, and it stops its `claude` rather than let it write next to another Claude.
- **Open elsewhere, without the mod:** if another Claude has the chat open but can't take messages from Sticky (sync is off, or the chat was open before sync was on), Sticky writes nothing to it. The sticky says so and offers **Open in Claude** and **Send as a copy** (a copy of the chat that this sticky shows from then on).

**The mod.** Turning sync on adds a small Claude Code mod, `sticky-bridge`, for your user. Its source is in [`mods/sticky-bridge`](mods/sticky-bridge). Sticky asks first, writes the mod into `~/Library/Application Support/Sticky/claude-mod/`, and runs:

```
claude plugin marketplace add <that folder> --scope user
claude plugin install sticky-bridge@sticky-local --scope user
```

These add the `sticky-local` marketplace and enable `sticky-bridge@sticky-local` in Claude Code's user settings (`~/.claude/settings.json`). In each Claude chat you run (in the Claude app, or `claude` in a terminal), the mod:

- writes a small lease file every 3 seconds: this chat is open, and whether a reply is running;
- checks Sticky's outbox for this chat twice a second, sends what Sticky left there as your own message (or stops the reply, for Stop), and writes an answer file.

It reads and writes only Sticky's bridge folder, `~/Library/Application Support/Sticky/bridge/`, and acts only on the files Sticky leaves in the outbox of its own chat. It never makes a folder: without the ones Sticky makes, it writes nothing. It refuses links and big files, makes no network calls, starts no processes and calls no MCP tools. In Sticky's own `claude` it does nothing, and neither does it in a `claude` that a chat's own tools start (a script's `claude -p`, say). Its log (`log.txt` in the bridge folder) has ids and states, never your messages. Sticky deletes the files it's done with and sweeps leftovers after a day.

**Turn it off** with the same menu item. Sticky runs `claude plugin uninstall sticky-bridge@sticky-local --scope user` and `claude plugin marketplace remove sticky-local`, and deletes the mod's folder. A chat whose Claude is already running keeps the mod until that process ends, but Sticky stops sending to it right away. When a new Sticky brings a new mod, Sticky rewrites the folder at launch, and chats load it when their process next starts.

**Limits**

- Chats already open in the Claude app picked up the mod within a few seconds of turning sync on (tested on the app's Claude Code 2.1.321). If one doesn't, quitting and reopening the Claude app restarts its process.
- Images can't go through the bridge. Add them in the Claude app.
- Permission prompts for a reply sent from Sticky show in the Claude app. Sticky says so when such a reply has shown nothing new for 20 seconds. The mode and model menus are locked for these chats: set them in the app.
- If the app doesn't pick a message up within 10 seconds, Sticky takes it back and puts it in the box again (in front of anything you typed since). If the app's plugins reload after the mod took a message but before it sent it, Sticky says so and puts it back too: check the chat before you send it again.
- If you close a new chat's sticky before its first reply ends, the chat stays in Sticky only. A failed move says why, and the chat goes on in Sticky. The app names a moved chat "Untitled" until it gives it a title.

## Sticky shortcuts

These work in web, terminal, chat and note stickies (in a note sticky, ⌃Tab switches stickies; use ⌘P to switch notes). All of them can be changed (see **Keybindings** below).

| Action | Keys | Action | Keys |
|---|---|---|---|
| Sticky switcher | ⌃⇥ (in a sticky) / ⌥⇥ (anywhere) | Show / hide all stickies (global) | ⌃⌥Space |
| Hide sticky | ⌘W or the red button | Close sticky for good | ⇧⌘W |
| New web sticky (site list) | ⌘T | Open a site in this sticky | ⌘L |
| Save / unsave this site | ⌘D | Zoom in / out / reset | ⌘= / ⌘- / ⌘0 |
| Open a Claude chat (search them all) | ⌘O | | |

In the switcher: Tab or arrows move, let go of ⌃ to stack it here, Return to open separately (it leaves its stack), **H** hides the highlighted sticky, **W** closes it for good, Esc cancels. The menu bar also lists every sticky, with stacks grouped (the ones waiting behind are indented): click one to show it (on top of its stack) or hide it, or hold ⌥ to close it.

Saved sites live in `~/.config/sticky/sites.json`, so you can edit or reorder them by hand. If nothing matches what you type, Return opens it as an address (one word becomes `word.com`) or searches the web.

## Note shortcuts

All of these can be changed (see **Keybindings** below).

| Action | Keys | Action | Keys |
|---|---|---|---|
| Show / hide notes (global) | ⌃⌘B | New note (global) | ⌃⌥N |
| Browse / search notes | ⌘P | Actions menu | ⌘K |
| New note | ⌘N | Pin / unpin | ⇧⌘P |
| Open pinned note 1–9 | ⌘1–⌘9 | Next / previous recent note | ⌃⇥ / ⌃⇧⇥ |
| Back / forward | ⌘[ / ⌘] | Find in note | ⌘F |
| Zoom in / out / reset | ⌘= / ⌘- / ⌘0 | Hide notes window | Esc |
| Copy note as Markdown | ⇧⌘C | Pop out note as a sticky | ⇧⌘N |
| Bold / italic / underline | ⌘B / ⌘I / ⌘U | Strikethrough | ⇧⌘S |
| Inline code / link | ⌘E / ⌘L | Code block | ⌥⌘C |
| Heading 1 / 2 / 3 | ⌥⌘1 / 2 / 3 | Blockquote | ⇧⌘B |
| Numbered / bullet / task list | ⇧⌘7 / 8 / 9 | Check / uncheck task | ⌘↩ |
| Move line up / down | ⌥⇧↑ / ⌥⇧↓ | Delete, duplicate, show in Finder | ⌘K menu |

## Keybindings

Every shortcut lives in `~/.config/sticky/keybindings.json` (menu bar → **Edit Keybindings…**). Write keys like `"cmd+shift+p"`, `"ctrl+tab"` or `"opt+shift+up"`. Use `""` to turn one off, or a list like `["cmd+p", "cmd+j"]` for several. Changes apply as soon as you save.

## Extensions (web stickies)

Web stickies can run browser extensions through Apple's WebExtension support (macOS 15.4+). Menu bar → **Add Extension…** and pick an unpacked extension folder, a `.zip` (like GitHub's *Download ZIP*), or a `.crx`. Extensions live in `~/.config/sticky/extensions/`; delete a folder and relaunch to remove one. Each extension with a popup gets a menu item that opens its settings.

WebKit doesn't send extensions the `runtime.onInstalled` event in apps like Sticky, so Sticky adds a tiny script in front of each extension's background script that fires it once per version. That's where many extensions save their default settings.

Simple extensions that restyle or tweak pages work well (for example [Better Canvas](https://github.com/UseBetterCanvas/bettercanvas)). Extensions that talk to a desktop app, like password managers, won't.

## Phone app (sync)

`web/` is a small Cloudflare Worker that stores your notes in a D1 database and serves a phone web app with the same live Markdown editing, checklists and search. Changes show up on the other device in about a second: Sticky watches `~/Documents/Sticky Notes`, and both apps keep a live WebSocket to a Durable Object that pings the other devices after every save (with a 30–60 second poll as a fallback). Each device has its own ID, so a save whose reply got lost (say, you reloaded mid-save) never counts as a conflict. If two devices really do edit the same note at once, the device that notices asks you what to do: keep its version, use the other device's, or keep both (yours is saved as a `-conflict-` copy). Nothing is overwritten without asking. Deleting on either side moves the Mac's file to the Trash.

Every API call needs a secret key, so the notes aren't public.

**Set up your own:**

```bash
cd web && npm install
npx wrangler d1 create sticky-notes        # copy the database_id into wrangler.toml
npx wrangler d1 execute sticky-notes --remote --file=schema.sql
openssl rand -base64 32 | tr -d '/+=\n' | npx wrangler secret put SYNC_KEY
npm run deploy                             # prints your https://….workers.dev URL
```

Then create `~/.config/sticky/sync.json` (chmod 600) with `{"url": "https://…workers.dev", "key": "<the same key>"}` and relaunch Sticky. The menu gets **Sync Notes Now**, **Copy Phone Sync Key** and **Open Notes on the Web**.

On the iPhone: open the URL in Safari → Share → **Add to Home Screen**, open it from the Home Screen, and paste the key (copy it on the Mac with **Copy Phone Sync Key**; Universal Clipboard carries it over).

## Requirements

- macOS 14 or later
- Swift toolchain (Xcode or Command Line Tools: `xcode-select --install`)
- For Claude stickies: [Claude Code](https://claude.com/claude-code)

## Build and install

```bash
./build.sh
open ~/Applications/Sticky.app
```

`build.sh` builds a release binary, wraps it in `~/Applications/Sticky.app`, and ad-hoc signs it with a stable identifier, so a keychain "Always Allow" survives rebuilds.

## Notes

- **Keychain prompt:** the first time a web sticky saves login data, macOS asks to let Sticky use its "WebCrypto Master Key". WebKit creates this key itself. Click **Always Allow**.
- **Saved stickies:** `~/Library/Application Support/Sticky/stickies.json`. Builds from before chat stickies can't read a list that has one, and save an empty list over it. Before you run an older build, close chat stickies (⇧⌘W), or put back `stickies-backup.json` (next to it, the last list saved with a chat sticky in it) afterwards.
- **Claude chats stay local:** Sticky reads Claude Code's own chat files (`~/.claude/projects`) and the Claude app's chat titles, and never edits them itself. Sending continues a chat through the `claude` command on this Mac, which adds to that chat's file (or to a copy, see below), or, with Sync with Claude App on, through the Claude app's own process for that chat. Nothing goes through remote control or the cloud.
  - **Permissions:** Sticky never turns permission checks off (no bypass mode). In **Ask first**, Claude asks before any tool your Claude settings don't already allow (reading files and the like may not ask, as in the terminal). **Accept edits** and **Auto** let it run some tools without asking, as in the CLI. "Always allow" lasts only for that chat (while its sticky is open: Sticky starts each new `claude` for the chat with what you allowed), and its button names everything it allows. Sticky never edits Claude's settings files itself (only turning Sync with Claude App on or off changes them, through the `claude plugin` commands above).
  - **Folder trust:** in a folder Claude Code hasn't been told to trust, Sticky asks first ("Trust … ?"), because a folder's own Claude settings, hooks and MCP servers run when Claude starts there. Your answer is kept in `chat-trust.json`; `~/.claude.json` is only read.
  - **Open in another Claude:** when another Claude (the app or a terminal) has the chat open, Sticky never writes into it next to that Claude. With Sync with Claude App on and the mod in that chat, your message runs there (see **Sync with the Claude app**). Otherwise the sticky offers **Send as a copy**, which continues a copy of the chat, so the two never write into one file.
  - The ⌘O list is cached in `~/Library/Application Support/Sticky/chat-index.json`, and the chats Sticky started are listed in `chat-own.json` there.
- **Regular Mac apps can't be floated.** macOS doesn't let one app pin another app's window without disabling System Integrity Protection.

## Code

Stickies and the app are in [`Sources/Sticky/main.swift`](Sources/Sticky/main.swift). The chat sticky is [`ChatView.swift`](Sources/Sticky/ChatView.swift) (the glue), [`ChatPage.swift`](Sources/Sticky/ChatPage.swift) (the chat page), [`ChatTranscript.swift`](Sources/Sticky/ChatTranscript.swift) (reads one chat file), [`ChatIndex.swift`](Sources/Sticky/ChatIndex.swift) (the ⌘O list), [`ClaudeProcess.swift`](Sources/Sticky/ClaudeProcess.swift) (runs `claude`) and [`ClaudeBridge.swift`](Sources/Sticky/ClaudeBridge.swift) (Sync with Claude App: the bridge folder, the `claude://` links, installing the mod). The mod itself is in [`mods/sticky-bridge`](mods/sticky-bridge); after you change it, run `mods/embed.sh`, which copies it into [`ClaudeBridgeMod.swift`](Sources/Sticky/ClaudeBridgeMod.swift) (Sticky installs it from there; `mods/embed.sh --check` says whether that file is up to date). The terminal uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

## License

MIT
