# Sticky

Floating, always-on-top windows for macOS. Each sticky runs a terminal command or a website, and stays visible over every app — fullscreen apps too, on every desktop.

## What it does

- **Claude Code (web) sticky** — opens `claude.ai/code` in a floating window. Turn on Remote Control in the Claude desktop app to drive sessions on your Mac from it.
- **Claude CLI sticky** — runs `claude` in a folder you pick.
- **Terminal sticky** — runs any command (`python3`, `htop`, `npm run dev`, …). When it exits you get a normal shell.
- **Web sticky** — any website. Sign-ins are saved.
- Fades to 40% when the mouse leaves and the window isn't focused.
- **⌃⌥Space** shows or hides all stickies (no Accessibility permission needed).
- Remembers each sticky's position and reopens them on launch.
- Optional **Open at Login** toggle in the menu.
- Lives in the menu bar, no Dock icon.

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
