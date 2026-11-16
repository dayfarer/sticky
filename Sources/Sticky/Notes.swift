// Note stickies: a plain-text Markdown editor that styles itself as you type.
import AppKit

extension Notification.Name {
    static let stickyRestyleNotes = Notification.Name("StickyRestyleNotes")
}

// MARK: - Notes on disk

enum NotesFolder {
    static let url: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Sticky Notes")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
}

struct NoteInfo {
    let id: String  // file name inside the notes folder, or a full path
    let url: URL
    let title: String
    let body: String
    let modified: Date
}

/// Shift+Return makes a line break inside a paragraph. In the editor that's U+2028;
/// in the .md file it's a standard Markdown hard break (two spaces before the newline).
enum LineBreaks {
    static let separator = "\u{2028}"
    private static let hardBreak = try! NSRegularExpression(pattern: " {2,}\n")

    static func toEditor(_ file: String) -> String {
        let ns = file as NSString
        return hardBreak.stringByReplacingMatches(in: file, range: NSRange(location: 0, length: ns.length),
                                                  withTemplate: separator)
    }

    static func toFile(_ editor: String) -> String {
        editor.replacingOccurrences(of: separator, with: "  \n")
    }

    static func toPlain(_ editor: String) -> String {
        editor.replacingOccurrences(of: separator, with: "\n")
    }
}

enum NotesLibrary {
    static func url(for id: String) -> URL {
        id.hasPrefix("/") ? URL(fileURLWithPath: id) : NotesFolder.url.appendingPathComponent(id)
    }

    static func newID() -> String {
        "note-\(UUID().uuidString.prefix(8).lowercased()).md"
    }

    static func title(of text: String) -> String {
        let first = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let t = first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*[] \t")) } ?? ""
        return t.isEmpty ? "New Note" : String(t.prefix(50))
    }

    /// Every .md note in the folder, most recently edited first.
    static func all() -> [NoteInfo] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: NotesFolder.url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "md" }.compactMap { u in
            let body = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return NoteInfo(id: u.lastPathComponent, url: u, title: title(of: body), body: body, modified: mod)
        }.sorted { $0.modified > $1.modified }
    }

    static func info(for id: String) -> NoteInfo? {
        let u = url(for: id)
        guard let body = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return NoteInfo(id: id, url: u, title: title(of: body), body: body, modified: mod)
    }
}

/// Pinned notes and zoom, saved in Application Support.
@MainActor final class NotesState {
    static let shared = NotesState()

    private struct Saved: Codable {
        var pinned: [String] = []
        var zoom: Double = 1
    }

    private static let file = Store.file.deletingLastPathComponent().appendingPathComponent("notes-state.json")
    private var saved = Saved()

    private init() {
        if let d = try? Data(contentsOf: Self.file), let s = try? JSONDecoder().decode(Saved.self, from: d) { saved = s }
        Markdown.scale = CGFloat(saved.zoom)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(saved) { try? d.write(to: Self.file) }
    }

    var pinned: [String] { saved.pinned }

    func isPinned(_ id: String) -> Bool { saved.pinned.contains(id) }

    func togglePin(_ id: String) {
        if let i = saved.pinned.firstIndex(of: id) { saved.pinned.remove(at: i) } else { saved.pinned.append(id) }
        save()
    }

    func unpin(_ id: String) {
        saved.pinned.removeAll { $0 == id }
        save()
    }

    var zoom: CGFloat {
        get { CGFloat(saved.zoom) }
        set {
            saved.zoom = Double(min(max(newValue, 0.6), 2.5))
            Markdown.scale = CGFloat(saved.zoom)
            save()
            NotificationCenter.default.post(name: .stickyRestyleNotes, object: nil)
        }
    }
}

// MARK: - Live Markdown styling

enum Markdown {
    static var scale: CGFloat = 1
    static var base: NSFont { .systemFont(ofSize: 14 * scale) }
    static var mono: NSFont { .monospacedSystemFont(ofSize: 13 * scale, weight: .regular) }
    static let codeBackground = NSColor.secondaryLabelColor.withAlphaComponent(0.12)

    private static func rx(_ p: String, _ o: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }

    static let fence     = rx(#"^```.*?^```[ \t]*$"#, [.anchorsMatchLines, .dotMatchesLineSeparators])
    static let code      = rx(#"`([^`\n]+)`"#)
    static let heading   = rx(#"^(#{1,6})[ \t]+.*$"#)
    static let bold      = rx(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    static let italic    = rx(#"(?<![\*\w])([\*_])(?![\s\*_])(.+?)(?<![\s\*_])\1(?![\*\w])"#)
    static let strike    = rx(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    static let underline = rx(#"<u>(.+?)</u>"#)
    static let quote     = rx(#"^(>[ \t]?).*$"#)
    static let bullet    = rx(#"^[ \t]*([-*+]|\d+[.)])[ \t]"#)
    static let task      = rx(#"^([ \t]*[-*+][ \t])\[([ xX])\][ \t]?(.*)$"#)
    static let link      = rx(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    static let rule      = rx(#"^([-*_])\1{2,}[ \t]*$"#)

    /// Restyles the whole note. Notes are small, so this is fast enough per keystroke.
    static func style(_ ts: NSTextStorage) {
        let str = ts.string
        let full = NSRange(location: 0, length: (str as NSString).length)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3 * scale
        para.paragraphSpacing = 9 * scale
        let base = self.base, mono = self.mono
        ts.setAttributes([.font: base, .foregroundColor: NSColor.labelColor, .paragraphStyle: para], range: full)

        let dim = NSColor.tertiaryLabelColor
        func each(_ r: NSRegularExpression, _ f: (NSTextCheckingResult) -> Void) {
            r.enumerateMatches(in: str, range: full) { m, _, _ in if let m { f(m) } }
        }
        func dimEnds(_ r: NSRange, _ open: Int, _ close: Int? = nil) {
            let close = close ?? open
            ts.addAttribute(.foregroundColor, value: dim, range: NSRange(location: r.location, length: open))
            ts.addAttribute(.foregroundColor, value: dim, range: NSRange(location: NSMaxRange(r) - close, length: close))
        }

        // Code first, so other rules skip it.
        var codeRanges: [NSRange] = []
        each(fence) { m in
            codeRanges.append(m.range)
            ts.addAttributes([.font: mono, .backgroundColor: codeBackground], range: m.range)
        }
        func inCode(_ r: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, r).length > 0 } }
        each(code) { m in
            guard !inCode(m.range) else { return }
            codeRanges.append(m.range)
            ts.addAttributes([.font: mono, .backgroundColor: codeBackground], range: m.range)
            dimEnds(m.range, 1)
        }

        each(heading) { m in
            guard !inCode(m.range) else { return }
            let sizes: [CGFloat] = [24, 20, 17, 15, 14, 14]
            let level = m.range(at: 1).length
            ts.addAttribute(.font, value: NSFont.systemFont(ofSize: sizes[level - 1] * scale, weight: .bold), range: m.range)
            ts.addAttribute(.foregroundColor, value: dim, range: m.range(at: 1))
        }
        each(bold) { m in
            guard !inCode(m.range) else { return }
            addTrait(ts, m.range, .boldFontMask)
            dimEnds(m.range, 2)
        }
        each(italic) { m in
            guard !inCode(m.range) else { return }
            addTrait(ts, m.range, .italicFontMask)
            dimEnds(m.range, 1)
        }
        each(strike) { m in
            guard !inCode(m.range) else { return }
            ts.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                              .foregroundColor: NSColor.secondaryLabelColor], range: m.range)
            dimEnds(m.range, 2)
        }
        each(underline) { m in
            guard !inCode(m.range) else { return }
            ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            dimEnds(m.range, 3, 4)
        }
        each(quote) { m in
            guard !inCode(m.range) else { return }
            ts.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range)
            ts.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: m.range(at: 1))
        }
        each(bullet) { m in
            guard !inCode(m.range) else { return }
            ts.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: m.range(at: 1))
        }
        each(task) { m in
            guard !inCode(m.range) else { return }
            let box = NSRange(location: NSMaxRange(m.range(at: 1)), length: 3)
            ts.addAttributes([.foregroundColor: NSColor.controlAccentColor, .font: mono], range: box)
            if (str as NSString).substring(with: m.range(at: 2)) != " " {
                ts.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                  .foregroundColor: NSColor.secondaryLabelColor], range: m.range(at: 3))
            }
        }
        each(link) { m in
            guard !inCode(m.range) else { return }
            ts.addAttribute(.foregroundColor, value: dim, range: m.range)
            ts.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range(at: 1))
            let target = (str as NSString).substring(with: m.range(at: 2))
            if let u = URL(string: target) { ts.addAttribute(.link, value: u, range: m.range(at: 1)) }
        }
        each(rule) { m in
            guard !inCode(m.range) else { return }
            ts.addAttribute(.foregroundColor, value: dim, range: m.range)
        }
    }

    private static func addTrait(_ ts: NSTextStorage, _ r: NSRange, _ t: NSFontTraitMask) {
        ts.enumerateAttribute(.font, in: r) { v, sub, _ in
            let f = (v as? NSFont) ?? base
            ts.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: t), range: sub)
        }
    }
}

// MARK: - Text view: formatting commands and clickable checkboxes

final class MarkdownTextView: NSTextView {
    private enum LineKind { case bullet, ordered, task, quote }

    private static let prefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-*+] \[[ xX]\] ?|[-*+] |\d+[.)] |> ?)?(.*)$"#)
    private static let headingPrefix = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+"#)

    /// Copy with normal newlines, so pasting elsewhere looks right.
    override func copy(_ sender: Any?) {
        let r = selectedRange()
        guard r.length > 0 else { return super.copy(sender) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LineBreaks.toPlain((string as NSString).substring(with: r)), forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        copy(sender)
        replace(selectedRange(), with: "")
    }

    override func mouseDown(with event: NSEvent) {
        let idx = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if toggleCheckbox(at: idx) { return }
        super.mouseDown(with: event)
    }

    /// Runs a formatting action. Returns false if the action isn't a formatting one.
    func perform(_ a: Action) -> Bool {
        switch a {
        case .bold: wrap("**")
        case .italic: wrap("*")
        case .underline: wrap("<u>", "</u>")
        case .strike: wrap("~~")
        case .code: wrap("`")
        case .link: insertLink()
        case .heading1: setHeading(1)
        case .heading2: setHeading(2)
        case .heading3: setHeading(3)
        case .codeBlock: toggleCodeBlock()
        case .quote: setLineKind(.quote)
        case .orderedList: setLineKind(.ordered)
        case .bulletList: setLineKind(.bullet)
        case .taskList: setLineKind(.task)
        case .toggleTask: toggleTasks()
        case .moveLineUp: moveLines(up: true)
        case .moveLineDown: moveLines(up: false)
        default: return false
        }
        return true
    }

    /// Undo-friendly replace.
    func replace(_ r: NSRange, with s: String) {
        guard shouldChangeText(in: r, replacementString: s) else { return }
        textStorage?.replaceCharacters(in: r, with: s)
        didChangeText()
    }

    private var ns: NSString { string as NSString }

    private func toggleCheckbox(at idx: Int) -> Bool {
        guard ns.length > 0, idx <= ns.length else { return false }
        let line = ns.lineRange(for: NSRange(location: min(idx, ns.length - 1), length: 0))
        let text = ns.substring(with: line)
        guard let m = Markdown.task.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        else { return false }
        let boxStart = line.location + NSMaxRange(m.range(at: 1))
        guard idx >= boxStart, idx <= boxStart + 3 else { return false }
        let inner = NSRange(location: boxStart + 1, length: 1)
        replace(inner, with: ns.substring(with: inner) == " " ? "x" : " ")
        return true
    }

    private func wrap(_ open: String, _ close: String? = nil) {
        let close = close ?? open
        let r = selectedRange()
        let sel = ns.substring(with: r)
        let o = (open as NSString).length, c = (close as NSString).length
        // Markers just outside the selection: remove them.
        if r.location >= o, NSMaxRange(r) + c <= ns.length,
           ns.substring(with: NSRange(location: r.location - o, length: o)) == open,
           ns.substring(with: NSRange(location: NSMaxRange(r), length: c)) == close {
            replace(NSRange(location: r.location - o, length: r.length + o + c), with: sel)
            setSelectedRange(NSRange(location: r.location - o, length: r.length))
            return
        }
        // Markers inside the selection: remove them.
        let sl = (sel as NSString).length
        if sel.hasPrefix(open), sel.hasSuffix(close), sl >= o + c {
            let inner = (sel as NSString).substring(with: NSRange(location: o, length: sl - o - c))
            replace(r, with: inner)
            setSelectedRange(NSRange(location: r.location, length: (inner as NSString).length))
            return
        }
        replace(r, with: open + sel + close)
        setSelectedRange(NSRange(location: r.location + o, length: r.length))
    }

    private func insertLink() {
        let r = selectedRange()
        let sel = ns.substring(with: r)
        if sel.hasPrefix("http://") || sel.hasPrefix("https://") {
            replace(r, with: "[](\(sel))")
            setSelectedRange(NSRange(location: r.location + 1, length: 0))
        } else if sel.isEmpty {
            replace(r, with: "[](url)")
            setSelectedRange(NSRange(location: r.location + 1, length: 0))
        } else {
            replace(r, with: "[\(sel)](url)")
            setSelectedRange(NSRange(location: r.location + (sel as NSString).length + 3, length: 3))
        }
    }

    /// Replaces the selected lines with f(lines), keeping the cursor sensible.
    private func transformLines(_ f: ([String]) -> [String]) {
        let sel = selectedRange()
        var r = ns.lineRange(for: sel)
        var text = ns.substring(with: r)
        if text.hasSuffix("\n") { text.removeLast(); r.length -= 1 }
        let lines = text.components(separatedBy: "\n")
        let out = f(lines).joined(separator: "\n")
        let outLen = (out as NSString).length
        replace(r, with: out)
        if lines.count == 1 {
            let delta = outLen - r.length
            setSelectedRange(NSRange(location: min(max(r.location, sel.location + delta), r.location + outLen), length: 0))
        } else {
            setSelectedRange(NSRange(location: r.location, length: outLen))
        }
    }

    private func split(_ line: String) -> (indent: String, kind: LineKind?, rest: String) {
        let l = line as NSString
        guard let m = Self.prefix.firstMatch(in: line, range: NSRange(location: 0, length: l.length)) else {
            return ("", nil, line)
        }
        let indent = l.substring(with: m.range(at: 1))
        let rest = l.substring(with: m.range(at: 3))
        var kind: LineKind?
        if m.range(at: 2).location != NSNotFound {
            let p = l.substring(with: m.range(at: 2))
            if p.contains("[") { kind = .task }
            else if p.hasPrefix(">") { kind = .quote }
            else if p.first?.isNumber == true { kind = .ordered }
            else { kind = .bullet }
        }
        return (indent, kind, rest)
    }

    private func setLineKind(_ kind: LineKind) {
        transformLines { lines in
            let parts = lines.map(split)
            let nonEmpty = parts.filter { !$0.rest.isEmpty || $0.kind != nil }
            let turnOff = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.kind == kind }
            var n = 0
            return parts.map { p in
                if turnOff { return p.indent + p.rest }
                if lines.count > 1, p.rest.isEmpty, p.kind == nil { return p.indent }
                n += 1
                switch kind {
                case .bullet: return p.indent + "- " + p.rest
                case .ordered: return p.indent + "\(n). " + p.rest
                case .task: return p.indent + "- [ ] " + p.rest
                case .quote: return p.indent + "> " + p.rest
                }
            }
        }
    }

    private func setHeading(_ level: Int) {
        transformLines { lines in
            lines.map { line in
                let l = line as NSString
                var had = 0
                var body = line
                if let m = Self.headingPrefix.firstMatch(in: line, range: NSRange(location: 0, length: l.length)) {
                    had = m.range(at: 1).length
                    body = l.substring(from: m.range.length)
                }
                return had == level ? body : String(repeating: "#", count: level) + " " + body
            }
        }
    }

    private func toggleCodeBlock() {
        let sel = selectedRange()
        let r = ns.lineRange(for: sel)
        let lines = ns.substring(with: r).components(separatedBy: "\n")
        let empty = sel.length == 0 && ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        transformLines { lines in
            if lines.count >= 2, lines.first?.hasPrefix("```") == true, lines.last == "```" {
                return Array(lines.dropFirst().dropLast())
            }
            return ["```"] + lines + ["```"]
        }
        if empty, lines.count <= 2 { setSelectedRange(NSRange(location: r.location + 4, length: 0)) }
    }

    private func toggleTasks() {
        transformLines { lines in
            lines.map { line in
                let l = line as NSString
                if let m = Markdown.task.firstMatch(in: line, range: NSRange(location: 0, length: l.length)) {
                    let box = m.range(at: 2)
                    return l.replacingCharacters(in: box, with: l.substring(with: box) == " " ? "x" : " ")
                }
                let p = split(line)
                return p.indent + "- [ ] " + p.rest
            }
        }
    }

    private func moveLines(up: Bool) {
        let sel = selectedRange()
        let block = ns.lineRange(for: sel)
        let offset = sel.location - block.location
        var blockText = ns.substring(with: block)
        if up {
            guard block.location > 0 else { return }
            let prev = ns.lineRange(for: NSRange(location: block.location - 1, length: 0))
            var prevText = ns.substring(with: prev)
            if !blockText.hasSuffix("\n") { blockText += "\n"; prevText.removeLast() }
            replace(NSRange(location: prev.location, length: prev.length + block.length), with: blockText + prevText)
            setSelectedRange(NSRange(location: prev.location + offset, length: sel.length))
        } else {
            guard NSMaxRange(block) < ns.length else { return }
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            var nextText = ns.substring(with: next)
            if !nextText.hasSuffix("\n") { nextText += "\n"; blockText.removeLast() }
            replace(NSRange(location: block.location, length: block.length + next.length), with: nextText + blockText)
            setSelectedRange(NSRange(location: block.location + (nextText as NSString).length + offset, length: sel.length))
        }
    }
}

// MARK: - Editor (loads, styles, autosaves one .md file at a time)

@MainActor final class NoteEditor: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    private(set) var noteID: String
    private(set) var fileURL: URL
    let scroll: NSScrollView
    let textView: MarkdownTextView
    var onTitle: ((String) -> Void)?
    private var pendingSave: DispatchWorkItem?
    private var dirty = false
    private var loading = false

    private static let listPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-*+] \[[ xX]\] |[-*+] |(\d+)([.)]) |> )"#)

    /// Every open editor, so sync can tell which notes are mid-edit.
    private static let registry = NSHashTable<NoteEditor>.weakObjects()
    static var open: [NoteEditor] { registry.allObjects }
    var hasUnsavedChanges: Bool { dirty }

    init(noteID: String, frame: NSRect) {
        self.noteID = noteID
        fileURL = NotesLibrary.url(for: noteID)
        scroll = NSScrollView(frame: frame)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let size = scroll.contentSize
        textView = MarkdownTextView(frame: NSRect(origin: .zero, size: size))
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        scroll.documentView = textView
        super.init()

        textView.delegate = self
        textView.textStorage?.delegate = self
        NotificationCenter.default.addObserver(forName: .stickyRestyleNotes, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restyle() }
        }
        NotificationCenter.default.addObserver(forName: .stickyNoteFileChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let id = n.object as? String, id == self.noteID else { return }
                self.reloadFromDisk()
            }
        }
        // The same note open in another editor here (say, the notes window and a note sticky): show its saves.
        NotificationCenter.default.addObserver(forName: .stickyNoteSaved, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let id = n.object as? String, id == self.noteID,
                      n.userInfo?["editor"] as? ObjectIdentifier != ObjectIdentifier(self) else { return }
                self.reloadFromDisk()
            }
        }
        Self.registry.add(self)
        load(noteID)
    }

    var title: String { NotesLibrary.title(of: textView.string) }
    /// Note text as saved in the file.
    var text: String { LineBreaks.toFile(textView.string) }

    /// Shows another note in this editor (saves the current one first).
    func load(_ id: String, initialText: String? = nil) {
        saveNow()
        noteID = id
        fileURL = NotesLibrary.url(for: id)
        loading = true
        textView.string = LineBreaks.toEditor(initialText ?? (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
        loading = false
        dirty = initialText != nil
        restyle()
        textView.undoManager?.removeAllActions()
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: initialText != nil ? end : 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        if dirty { saveNow() }
        onTitle?(title)
    }

    /// Sync changed this note's file: show the new text if there's no unsaved typing.
    func reloadFromDisk() {
        guard !dirty, let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let text = LineBreaks.toEditor(raw)
        guard text != textView.string else { return }
        let sel = textView.selectedRange()
        loading = true
        textView.string = text
        loading = false
        restyle()
        let len = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
        onTitle?(title)
    }

    func restyle() {
        if let ts = textView.textStorage { Markdown.style(ts) }
        textView.typingAttributes[.font] = Markdown.base
    }

    /// Writes the note if it has unsaved changes.
    func saveNow() {
        pendingSave?.cancel()
        guard dirty else { return }
        dirty = false
        try? LineBreaks.toFile(textView.string).write(to: fileURL, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: .stickyNoteSaved, object: noteID, userInfo: ["editor": ObjectIdentifier(self)])
    }

    /// Forget unsaved changes (used before deleting a note).
    func discard() {
        pendingSave?.cancel()
        dirty = false
    }

    func showFind() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }

    // Restyle after every edit.
    func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                     range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters) else { return }
        Markdown.style(ts)
    }

    // Autosave half a second after you stop typing.
    func textDidChange(_ n: Notification) {
        guard !loading else { return }
        dirty = true
        onTitle?(title)
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                tv.insertText(LineBreaks.separator, replacementRange: tv.selectedRange())
                return true
            }
            return continueList(tv)
        case #selector(NSResponder.insertTab(_:)): return indent(tv, inward: true)
        case #selector(NSResponder.insertBacktab(_:)): return indent(tv, inward: false)
        default: return false
        }
    }

    /// Enter on a list line starts the next item; Enter on an empty item ends the list.
    private func continueList(_ tv: NSTextView) -> Bool {
        let s = tv.string as NSString
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let lr = s.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = s.substring(with: NSRange(location: lr.location, length: sel.location - lr.location)) as NSString
        guard let m = Self.listPrefix.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length))
        else { return false }

        if m.range.length == line.length {  // empty item: remove the marker
            tv.insertText("", replacementRange: NSRange(location: lr.location, length: m.range.length))
            return true
        }
        let indent = line.substring(with: m.range(at: 1))
        let marker = line.substring(with: m.range(at: 2))
        let next: String
        if m.range(at: 3).location != NSNotFound {
            let n = (Int(line.substring(with: m.range(at: 3))) ?? 0) + 1
            next = indent + "\(n)" + line.substring(with: m.range(at: 4)) + " "
        } else if marker.contains("[") {
            next = indent + String(marker.prefix(2)) + "[ ] "
        } else {
            next = indent + marker
        }
        tv.insertText("\n" + next, replacementRange: sel)
        return true
    }

    /// Tab / Shift-Tab indent list lines.
    private func indent(_ tv: NSTextView, inward: Bool) -> Bool {
        let s = tv.string as NSString
        let sel = tv.selectedRange()
        let lr = s.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = s.substring(with: lr)
        guard Markdown.bullet.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        else { return false }
        if inward {
            tv.insertText("  ", replacementRange: NSRange(location: lr.location, length: 0))
            tv.setSelectedRange(NSRange(location: sel.location + 2, length: sel.length))
        } else {
            let n = line.hasPrefix("  ") ? 2 : (line.hasPrefix("\t") ? 1 : 0)
            guard n > 0 else { return true }
            tv.insertText("", replacementRange: NSRange(location: lr.location, length: n))
            tv.setSelectedRange(NSRange(location: max(lr.location, sel.location - n), length: sel.length))
        }
        return true
    }
}
