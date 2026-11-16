// Custom keybindings, loaded from ~/.config/sticky/keybindings.json and reloaded when it changes.
import AppKit
import Carbon

enum Action: String, CaseIterable {
    // Global (work from any app)
    case toggleNotes, newNoteGlobal, toggleAll
    // Notes window
    case newNote, browseNotes, actionPanel, togglePin, deleteNote, duplicateNote, copyNote
    case revealNote, openInNewSticky, back, forward, nextRecent, prevRecent
    case pinned1, pinned2, pinned3, pinned4, pinned5, pinned6, pinned7, pinned8, pinned9
    case zoomIn, zoomOut, zoomReset, find, hideNotes, editKeybindings
    // Formatting
    case bold, italic, underline, strike, code, link
    case heading1, heading2, heading3, codeBlock, quote, orderedList, bulletList, taskList, toggleTask
    case moveLineUp, moveLineDown

    var isGlobal: Bool { [.toggleNotes, .newNoteGlobal, .toggleAll].contains(self) }

    var pinIndex: Int? {
        let all: [Action] = [.pinned1, .pinned2, .pinned3, .pinned4, .pinned5, .pinned6, .pinned7, .pinned8, .pinned9]
        return all.firstIndex(of: self)
    }

    var title: String {
        switch self {
        case .toggleNotes: return "Show / Hide Notes"
        case .newNoteGlobal: return "New Note (from anywhere)"
        case .toggleAll: return "Show / Hide Stickies (not notes)"
        case .newNote: return "New Note"
        case .browseNotes: return "Browse Notes"
        case .actionPanel: return "Show Actions"
        case .togglePin: return "Pin / Unpin Note"
        case .deleteNote: return "Delete Note (moves to Trash)"
        case .duplicateNote: return "Duplicate Note"
        case .copyNote: return "Copy Note as Markdown"
        case .revealNote: return "Show Note in Finder"
        case .openInNewSticky: return "Open Note in New Window"
        case .back: return "Back"
        case .forward: return "Forward"
        case .nextRecent: return "Next Recent Note"
        case .prevRecent: return "Previous Recent Note"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .zoomReset: return "Reset Zoom"
        case .find: return "Find in Note"
        case .hideNotes: return "Hide Notes Window"
        case .editKeybindings: return "Edit Keybindings…"
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .underline: return "Underline"
        case .strike: return "Strikethrough"
        case .code: return "Inline Code"
        case .link: return "Link"
        case .heading1: return "Heading 1"
        case .heading2: return "Heading 2"
        case .heading3: return "Heading 3"
        case .codeBlock: return "Code Block"
        case .quote: return "Blockquote"
        case .orderedList: return "Numbered List"
        case .bulletList: return "Bullet List"
        case .taskList: return "Task List"
        case .toggleTask: return "Check / Uncheck Task"
        case .moveLineUp: return "Move Line Up"
        case .moveLineDown: return "Move Line Down"
        default: return "Open Pinned Note \((pinIndex ?? 0) + 1)"
        }
    }

    var defaultKeys: [String] {
        switch self {
        case .toggleNotes: return ["ctrl+cmd+b"]
        case .newNoteGlobal: return ["ctrl+opt+n"]
        case .toggleAll: return ["ctrl+opt+space"]
        case .newNote: return ["cmd+n"]
        case .browseNotes: return ["cmd+p"]
        case .actionPanel: return ["cmd+k"]
        case .togglePin: return ["cmd+shift+p"]
        case .deleteNote, .duplicateNote, .revealNote, .editKeybindings: return []
        case .copyNote: return ["cmd+shift+c"]
        case .openInNewSticky: return ["cmd+shift+n"]
        case .back: return ["cmd+["]
        case .forward: return ["cmd+]"]
        case .nextRecent: return ["ctrl+tab"]
        case .prevRecent: return ["ctrl+shift+tab"]
        case .zoomIn: return ["cmd+="]
        case .zoomOut: return ["cmd+-"]
        case .zoomReset: return ["cmd+0"]
        case .find: return ["cmd+f"]
        case .hideNotes: return ["esc"]
        case .bold: return ["cmd+b"]
        case .italic: return ["cmd+i"]
        case .underline: return ["cmd+u"]
        case .strike: return ["cmd+shift+s"]
        case .code: return ["cmd+e"]
        case .link: return ["cmd+l"]
        case .heading1: return ["cmd+opt+1"]
        case .heading2: return ["cmd+opt+2"]
        case .heading3: return ["cmd+opt+3"]
        case .codeBlock: return ["cmd+opt+c"]
        case .quote: return ["cmd+shift+b"]
        case .orderedList: return ["cmd+shift+7"]
        case .bulletList: return ["cmd+shift+8"]
        case .taskList: return ["cmd+shift+9"]
        case .toggleTask: return ["cmd+enter"]
        case .moveLineUp: return ["opt+shift+up"]
        case .moveLineDown: return ["opt+shift+down"]
        default: return ["cmd+\((pinIndex ?? 0) + 1)"]
        }
    }
}

struct KeyCombo: Hashable {
    let keyCode: UInt16
    let mods: UInt  // NSEvent.ModifierFlags raw value, only cmd/ctrl/opt/shift

    static let modMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    private static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
        "tab": kVK_Tab, "enter": kVK_Return, "return": kVK_Return, "esc": kVK_Escape, "escape": kVK_Escape,
        "space": kVK_Space, "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow,
        "right": kVK_RightArrow, "delete": kVK_Delete, "backspace": kVK_Delete,
    ]

    private static let symbols: [Int: String] = [
        kVK_Tab: "⇥", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Space: "Space", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_Delete: "⌫",
    ]

    init(keyCode: UInt16, mods: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.mods = mods.intersection(Self.modMask).rawValue
    }

    init(event: NSEvent) {
        self.init(keyCode: event.keyCode, mods: event.modifierFlags)
    }

    /// Parses strings like "cmd+shift+p", "ctrl+tab", "opt+shift+up".
    init?(_ text: String) {
        var flags: NSEvent.ModifierFlags = []
        var code: Int?
        let parts = text.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+", omittingEmptySubsequences: false)
        for (i, raw) in parts.enumerated() {
            // "cmd++" means the + key is not supported; "=" covers zoom in.
            let p = String(raw)
            switch p {
            case "cmd", "command", "⌘", "meta", "super": flags.insert(.command)
            case "ctrl", "control", "⌃": flags.insert(.control)
            case "opt", "option", "alt", "⌥": flags.insert(.option)
            case "shift", "⇧": flags.insert(.shift)
            default:
                guard i == parts.count - 1, let c = Self.keyCodes[p] else { return nil }
                code = c
            }
        }
        guard let code else { return nil }
        self.init(keyCode: UInt16(code), mods: flags)
    }

    var display: String {
        let f = NSEvent.ModifierFlags(rawValue: mods)
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        if let sym = Self.symbols[Int(keyCode)] { return s + sym }
        let name = Self.keyCodes.first { $0.value == Int(keyCode) && $0.key.count == 1 }?.key ?? "?"
        return s + name.uppercased()
    }

    var carbonMods: UInt32 {
        let f = NSEvent.ModifierFlags(rawValue: mods)
        var m = 0
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }
}

@MainActor final class Keymap {
    static let shared = Keymap()

    static let file: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/sticky")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("keybindings.json")
    }()

    private(set) var bindings: [Action: [KeyCombo]] = [:]
    private(set) var problems: [String] = []
    var onChange: (() -> Void)?
    private var lastModified: Date?

    private init() {
        writeDefaultsIfMissing()
        load()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { Keymap.shared.reloadIfChanged() }
        }
    }

    func combos(_ a: Action) -> [KeyCombo] { bindings[a] ?? [] }

    func shortcut(_ a: Action) -> String { combos(a).first?.display ?? "" }

    /// The in-window action bound to this key press, if any.
    func localAction(for event: NSEvent) -> Action? {
        let combo = KeyCombo(event: event)
        return Action.allCases.first { !$0.isGlobal && combos($0).contains(combo) }
    }

    private func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Self.file.path))?[.modificationDate] as? Date
    }

    private func reloadIfChanged() {
        guard modified() != lastModified else { return }
        load()
        onChange?()
    }

    private func load() {
        lastModified = modified()
        var user: [String: Any] = [:]
        if let data = try? Data(contentsOf: Self.file),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            user = obj
        }
        problems = []
        var out: [Action: [KeyCombo]] = [:]
        for a in Action.allCases {
            var keys = a.defaultKeys
            if let v = user[a.rawValue] as? String { keys = v.isEmpty ? [] : [v] }
            if let v = user[a.rawValue] as? [String] { keys = v }
            out[a] = keys.compactMap { k in
                if let c = KeyCombo(k) { return c }
                problems.append("\(a.rawValue): can't read \"\(k)\"")
                return nil
            }
        }
        bindings = out
    }

    private func writeDefaultsIfMissing() {
        guard !FileManager.default.fileExists(atPath: Self.file.path) else { return }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\") + "\"" }
        var lines = [
            "  \"_help\": \"Modifiers: cmd ctrl opt shift. Keys: a-z 0-9 - = [ ] ; ' , . / \\\\ ` tab enter esc space up down left right delete. Use \\\"\\\" to turn one off, or a list for several. Saving applies changes right away.\"",
        ]
        for a in Action.allCases {
            let v = a.defaultKeys
            let value = v.count == 1 ? q(v[0]) : "[" + v.map(q).joined(separator: ", ") + "]"
            lines.append("  \(q(a.rawValue)): \(value)")
        }
        let text = "{\n" + lines.joined(separator: ",\n") + "\n}\n"
        try? text.write(to: Self.file, atomically: true, encoding: .utf8)
    }
}
