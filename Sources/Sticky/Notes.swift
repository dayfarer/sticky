// Note stickies: a plain-text Markdown editor that styles itself as you type.
import AppKit

enum NotesFolder {
    static let url: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Sticky Notes")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
}

// MARK: - Live Markdown styling

enum Markdown {
    static let baseSize: CGFloat = 14
    static let base = NSFont.systemFont(ofSize: baseSize)
    static let mono = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
    static let codeBackground = NSColor.secondaryLabelColor.withAlphaComponent(0.12)

    private static func rx(_ p: String, _ o: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }

    static let fence   = rx(#"^```.*?^```[ \t]*$"#, [.anchorsMatchLines, .dotMatchesLineSeparators])
    static let code    = rx(#"`([^`\n]+)`"#)
    static let heading = rx(#"^(#{1,6})[ \t]+.*$"#)
    static let bold    = rx(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    static let italic  = rx(#"(?<![\*\w])([\*_])(?![\s\*_])(.+?)(?<![\s\*_])\1(?![\*\w])"#)
    static let strike  = rx(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    static let quote   = rx(#"^(>[ \t]?).*$"#)
    static let bullet  = rx(#"^[ \t]*([-*+]|\d+[.)])[ \t]"#)
    static let task    = rx(#"^([ \t]*[-*+][ \t])\[([ xX])\][ \t]?(.*)$"#)
    static let link    = rx(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    static let rule    = rx(#"^([-*_])\1{2,}[ \t]*$"#)

    /// Restyles the whole note. Notes are small, so this is fast enough per keystroke.
    static func style(_ ts: NSTextStorage) {
        let str = ts.string
        let full = NSRange(location: 0, length: (str as NSString).length)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        para.paragraphSpacing = 4
        ts.setAttributes([.font: base, .foregroundColor: NSColor.labelColor, .paragraphStyle: para], range: full)

        let dim = NSColor.tertiaryLabelColor
        func each(_ r: NSRegularExpression, _ f: (NSTextCheckingResult) -> Void) {
            r.enumerateMatches(in: str, range: full) { m, _, _ in if let m { f(m) } }
        }
        func dimEnds(_ r: NSRange, _ n: Int) {
            ts.addAttribute(.foregroundColor, value: dim, range: NSRange(location: r.location, length: n))
            ts.addAttribute(.foregroundColor, value: dim, range: NSRange(location: NSMaxRange(r) - n, length: n))
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
            ts.addAttribute(.font, value: NSFont.systemFont(ofSize: sizes[level - 1], weight: .bold), range: m.range)
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
            let checked = (str as NSString).substring(with: m.range(at: 2)) != " "
            if checked {
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

// MARK: - Text view with shortcuts and clickable checkboxes

final class MarkdownTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        let idx = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if toggleCheckbox(at: idx) { return }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: e) }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch key {
            case "b": wrap("**"); return true
            case "i": wrap("*"); return true
            case "e": wrap("`"); return true
            case "l": toggleChecklistLine(); return true
            default: break
            }
        }
        if flags == [.command, .shift], key == "x" { wrap("~~"); return true }
        return super.performKeyEquivalent(with: e)
    }

    /// Undo-friendly replace.
    func replace(_ r: NSRange, with s: String) {
        guard shouldChangeText(in: r, replacementString: s) else { return }
        textStorage?.replaceCharacters(in: r, with: s)
        didChangeText()
    }

    private func toggleCheckbox(at idx: Int) -> Bool {
        let s = string as NSString
        guard s.length > 0, idx <= s.length else { return false }
        let line = s.lineRange(for: NSRange(location: min(idx, s.length - 1), length: 0))
        let text = s.substring(with: line)
        guard let m = Markdown.task.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        else { return false }
        let boxStart = line.location + NSMaxRange(m.range(at: 1))
        guard idx >= boxStart, idx <= boxStart + 3 else { return false }
        let inner = NSRange(location: boxStart + 1, length: 1)
        replace(inner, with: s.substring(with: inner) == " " ? "x" : " ")
        return true
    }

    private func wrap(_ mark: String) {
        let r = selectedRange()
        let sel = (string as NSString).substring(with: r)
        let n = (mark as NSString).length
        if sel.hasPrefix(mark), sel.hasSuffix(mark), (sel as NSString).length >= 2 * n {
            let inner = String(sel.dropFirst(mark.count).dropLast(mark.count))
            replace(r, with: inner)
            setSelectedRange(NSRange(location: r.location, length: (inner as NSString).length))
            return
        }
        replace(r, with: mark + sel + mark)
        setSelectedRange(NSRange(location: r.location + n, length: (sel as NSString).length))
    }

    private func toggleChecklistLine() {
        let s = string as NSString
        var line = s.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        if line.length > 0, s.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
        let text = s.substring(with: line)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let rules: [(String, String)] = [
            (#"^([ \t]*)[-*+] \[[ xX]\] ?"#, "$1"),
            (#"^([ \t]*)[-*+] "#, "$1- [ ] "),
            (#"^([ \t]*)"#, "$1- [ ] "),
        ]
        for (pattern, template) in rules {
            let r = try! NSRegularExpression(pattern: pattern)
            guard r.firstMatch(in: text, range: whole) != nil else { continue }
            let out = r.stringByReplacingMatches(in: text, range: whole, withTemplate: template)
            replace(line, with: out)
            setSelectedRange(NSRange(location: line.location + (out as NSString).length, length: 0))
            return
        }
    }
}

// MARK: - Editor (loads, styles, autosaves one .md file)

final class NoteEditor: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let fileURL: URL
    let scroll: NSScrollView
    let textView: MarkdownTextView
    var onTitle: ((String) -> Void)?
    private var pendingSave: DispatchWorkItem?

    private static let listPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-*+] \[[ xX]\] |[-*+] |(\d+)([.)]) |> )"#)

    init(fileURL: URL, frame: NSRect) {
        self.fileURL = fileURL
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
        textView.font = Markdown.base
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        scroll.documentView = textView
        super.init()

        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.string = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        if let ts = textView.textStorage { Markdown.style(ts) }
    }

    var title: String {
        let first = textView.string.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let t = first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*[] \t")) } ?? ""
        return t.isEmpty ? "New Note" : String(t.prefix(40))
    }

    func saveNow() {
        pendingSave?.cancel()
        try? textView.string.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // Restyle after every edit.
    func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                     range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters) else { return }
        Markdown.style(ts)
    }

    // Autosave half a second after you stop typing.
    func textDidChange(_ n: Notification) {
        onTitle?(title)
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): return continueList(tv)
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
