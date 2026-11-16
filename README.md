# Sticky

Floating, always-on-top windows for macOS. Each sticky runs a terminal command or a website, and stays visible over every app — fullscreen apps too, on every desktop.

## What it does

- **Claude Code (web) sticky** — opens `claude.ai/code` in a floating window. Turn on Remote Control in the Claude desktop app to drive sessions on your Mac from it.
- **Claude CLI sticky** — runs `claude` in a folder you pick.
- **Terminal sticky** — runs any command (`python3`, `htop`, `npm run dev`, …). When it exits you get a normal shell.
- **Web sticky** — any website. Sign-ins are saved. ⌘- / ⌘= / ⌘0 zoom the page (or pinch), and each sticky remembers its zoom.
- **Notes** — works like Raycast Notes. **⌃⌘B** shows or hides the notes window, which shows one note at a time. Markdown formats as you type: headings, **bold**, *italic*, underline, ~~strike~~, `code`, code blocks, quotes, links, and clickable `- [ ]` checklists. Return starts a new paragraph (or list item), Shift+Return adds a line break in the same paragraph, Tab indents lists. Notes autosave as plain `.md` files in `~/Documents/Sticky Notes`.
- Fades to 40% when the mouse leaves and the window isn't focused.
- Notes and stickies stay separate. **⌃⌘B** only shows or hides the notes window, and **⌃⌥Space** only shows or hides the terminal and web stickies. Neither shortcut touches the other (no Accessibility permission needed).
- Remembers each sticky's position and reopens them on launch. The notes window stays hidden at launch until you press ⌃⌘B, and closing it only hides it, so it comes back in the same spot.
- Optional **Open at Login** toggle in the menu.
- Lives in the menu bar, no Dock icon.

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
| Copy note as Markdown | ⇧⌘C | Open note in new window | ⇧⌘N |
| Bold / italic / underline | ⌘B / ⌘I / ⌘U | Strikethrough | ⇧⌘S |
| Inline code / link | ⌘E / ⌘L | Code block | ⌥⌘C |
| Heading 1 / 2 / 3 | ⌥⌘1 / 2 / 3 | Blockquote | ⇧⌘B |
| Numbered / bullet / task list | ⇧⌘7 / 8 / 9 | Check / uncheck task | ⌘↩ |
| Move line up / down | ⌥⇧↑ / ⌥⇧↓ | Delete, duplicate, show in Finder | ⌘K menu |

## Keybindings

Every shortcut lives in `~/.config/sticky/keybindings.json` (menu bar → **Edit Keybindings…**). Write keys like `"cmd+shift+p"`, `"ctrl+tab"` or `"opt+shift+up"`. Use `""` to turn one off, or a list like `["cmd+p", "cmd+o"]` for several. Changes apply as soon as you save.

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
- **Saved stickies:** `~/Library/Application Support/Sticky/stickies.json`.
- **Regular Mac apps can't be floated.** macOS doesn't let one app pin another app's window without disabling System Integrity Protection.

## Code

Everything is in [`Sources/Sticky/main.swift`](Sources/Sticky/main.swift). The terminal uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

## License

MIT
