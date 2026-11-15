# Sticky

Floating, always-on-top windows for macOS. Each sticky runs a terminal command or a website, and stays visible over every app — fullscreen apps too, on every desktop.

## What it does

- **Claude Code (web) sticky** — opens `claude.ai/code` in a floating window. Turn on Remote Control in the Claude desktop app to drive sessions on your Mac from it.
- **Claude CLI sticky** — runs `claude` in a folder you pick.
- **Terminal sticky** — runs any command (`python3`, `htop`, `npm run dev`, …). When it exits you get a normal shell.
- **Web sticky** — any website. Sign-ins are saved.
- **Notes** — works like Raycast Notes. **⌃⌘B** shows or hides the notes window, which shows one note at a time. Markdown formats as you type: headings, **bold**, *italic*, underline, ~~strike~~, `code`, code blocks, quotes, links, and clickable `- [ ]` checklists. Enter continues lists, Tab indents them. Notes autosave as plain `.md` files in `~/Documents/Sticky Notes`.
- Fades to 40% when the mouse leaves and the window isn't focused.
- **⌃⌥Space** shows or hides all stickies (no Accessibility permission needed).
- Remembers each sticky's position and reopens them on launch.
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
| Copy note as Markdown | ⇧⌘C | Open note in new sticky | ⇧⌘N |
| Bold / italic / underline | ⌘B / ⌘I / ⌘U | Strikethrough | ⇧⌘S |
| Inline code / link | ⌘E / ⌘L | Code block | ⌥⌘C |
| Heading 1 / 2 / 3 | ⌥⌘1 / 2 / 3 | Blockquote | ⇧⌘B |
| Numbered / bullet / task list | ⇧⌘7 / 8 / 9 | Check / uncheck task | ⌘↩ |
| Move line up / down | ⌥⇧↑ / ⌥⇧↓ | Delete, duplicate, show in Finder | ⌘K menu |

## Keybindings

Every shortcut lives in `~/.config/sticky/keybindings.json` (menu bar → **Edit Keybindings…**). Write keys like `"cmd+shift+p"`, `"ctrl+tab"` or `"opt+shift+up"`. Use `""` to turn one off, or a list like `["cmd+p", "cmd+o"]` for several. Changes apply as soon as you save.

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
