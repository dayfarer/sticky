// Sticky — floating always-on-top windows for any terminal command or website.
import AppKit
import Carbon
import ServiceManagement
import SwiftTerm
import UniformTypeIdentifiers
import WebKit

// MARK: - Saved state

struct StickyConfig: Codable {
    enum Kind: String, Codable { case terminal, web, note }
    var id = UUID()
    var kind: Kind
    var command: String?
    var folder: String?
    var url: String?
    var frame: CGRect?
    var note: String?  // note file name in ~/Documents/Sticky Notes, or a full path
    var zoom: Double?  // web page zoom
    var hidden: Bool?  // hidden with the red button / ⌘W (still running)
    var noteSticky: Bool?  // a note shown as a sticky (⌃Tab, ⌘W hides it), not part of the notes window
    var stack: UUID?  // stickies with the same stack share one spot, like tabs: one shows, the rest wait behind it
    var used: Double?  // when you last used it, for ⌃Tab order and which sticky in a stack comes back next
    var popup: Bool?  // a sign-in popup a page opened: not saved, gone when the page closes it
}

enum Store {
    static let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sticky")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stickies.json")
    }()

    static func load() -> [StickyConfig] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([StickyConfig].self, from: data)) ?? []
    }

    static func save(_ configs: [StickyConfig]) {
        if let data = try? JSONEncoder().encode(configs) { try? data.write(to: file) }
    }
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Window

/// A panel that floats over every app (fullscreen too) without stealing app focus.
final class StickyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Sees every key press first, so custom keybindings win over the text view.
    var keyHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let h = keyHandler, h(event) { return }
        super.sendEvent(event)
    }
}

/// Tells us when the mouse enters or leaves the window, for the fade effect.
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

// MARK: - One sticky

@MainActor final class StickyController: NSObject, NSWindowDelegate, LocalProcessTerminalViewDelegate, WKUIDelegate, WKNavigationDelegate {
    static let fadedAlpha: CGFloat = 0.4

    var config: StickyConfig
    let panel: StickyPanel
    weak var app: AppDelegate?
    private var hovering = false
    private var term: LocalProcessTerminalView?
    private var web: WKWebView?
    private var titleObserver: NSKeyValueObservation?
    private var note: NoteEditor?
    private var urlObserver: NSKeyValueObservation?
    private var visitHost: String?
    private var visitNeedsTitle = false
    /// Restored at launch: the first page load isn't a new visit for site ranking.
    var skipFirstVisit = false
    /// For the ⌃Tab switcher: most recently used first, plus a picture of the sticky.
    var lastFocused: Date {
        get { config.used.map(Date.init(timeIntervalSince1970:)) ?? .distantPast }
        set { config.used = newValue.timeIntervalSince1970 }
    }
    var thumbnail: NSImage?
    private var thumbnailSoon: DispatchWorkItem?

    /// `webConfig`: a page asked for a new window, and WebKit gives the settings for it.
    init(config: StickyConfig, app: AppDelegate, cascade: Int, restoring: Bool = false, webConfig: WKWebViewConfiguration? = nil) {
        self.config = config
        self.app = app
        let start = CGRect(x: 160 + cascade * 30, y: 420 - cascade * 30, width: 560, height: 400)
        panel = StickyPanel(
            contentRect: start,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        if let saved = config.frame {
            panel.setFrame(saved, display: false)
        } else if config.kind == .note {
            panel.setContentSize(config.noteSticky == true ? NSSize(width: 320, height: 340) : NSSize(width: 380, height: 440))
        }

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 260, height: 160)

        let container = HoverView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        panel.contentView = container

        super.init()
        panel.delegate = self
        container.onHover = { [weak self] inside in
            self?.hovering = inside
            self?.updateAlpha()
        }

        skipFirstVisit = restoring
        switch config.kind {
        case .terminal: setUpTerminal(in: container)
        case .web: setUpWeb(in: container, given: webConfig)
        case .note: setUpNote(in: container)
        }
    }

    private func setUpTerminal(in container: NSView) {
        let t = LocalProcessTerminalView(frame: container.bounds)
        t.autoresizingMask = [.width, .height]
        t.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        t.processDelegate = self
        container.addSubview(t)
        term = t
        panel.keyHandler = { [weak self] e in self?.handleStickyKey(e) ?? false }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }

        let folder = config.folder ?? NSHomeDirectory()
        let command = config.command ?? "claude"
        // Run the command in a login shell so PATH matches your normal Terminal.
        // When it exits, drop into a plain shell instead of closing.
        let script = "cd \(shellQuote(folder)) && \(command); exec /bin/zsh -l"
        t.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-i", "-c", script],
            environment: env.map { "\($0.key)=\($0.value)" })
        panel.title = "\(command) — \((folder as NSString).lastPathComponent)"
    }

    private func setUpNote(in container: NSView) {
        let id = config.note ?? NotesLibrary.newID()
        config.note = id
        let editor = NoteEditor(noteID: id, frame: container.bounds)
        editor.onTitle = { [weak self] t in self?.updateNoteTitle(t) }
        container.addSubview(editor.scroll)
        note = editor
        history = [id]
        historyIndex = 0
        updateNoteTitle(editor.title)
        panel.keyHandler = { [weak self] e in self?.handleNoteKey(e) ?? false }
        NotificationCenter.default.addObserver(forName: .stickyNoteFileChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let note = self.note, let id = n.object as? String, id == note.noteID,
                      !FileManager.default.fileExists(atPath: note.fileURL.path), !note.hasUnsavedChanges else { return }
                note.discard()
                self.switchTo(NotesLibrary.all().first?.id ?? NotesLibrary.newID(), record: false)
            }
        }
    }

    // MARK: Note commands

    var isNote: Bool { note != nil }
    /// A note shown as a sticky: it joins ⌃Tab, the menu list and ⌃⌥Space, not ⌃⌘B.
    var isNoteSticky: Bool { isNote && config.noteSticky == true }
    /// The notes window (⌃⌘B), as opposed to stickies.
    var inNotesGroup: Bool { isNote && config.noteSticky != true }
    var symbolName: String { isWeb ? "globe" : isNote ? "note.text" : "terminal" }
    private var history: [String] = []
    private var historyIndex = 0

    private func updateNoteTitle(_ t: String) {
        guard let id = note?.noteID else { return }
        panel.title = (NotesState.shared.isPinned(id) ? "📌 " : "") + t
    }

    private func handleNoteKey(_ e: NSEvent) -> Bool {
        guard let note else { return false }
        // A note sticky is a sticky too: ⌃Tab switches stickies, ⇧⌘W closes it, ⌘T opens a site.
        if isNoteSticky, let a = Keymap.shared.localAction(for: e, in: .stickies),
           [.switchStickies, .switchStickiesBack, .closeSticky, .newWebSticky].contains(a) {
            return handleStickyKey(e)
        }
        guard let action = Keymap.shared.localAction(for: e, in: .notes) else { return false }
        if action == .hideNotes {
            if isNoteSticky { return false }  // Esc doesn't hide a note sticky (⌘W does)
            // Let Esc close the find bar instead of hiding the window.
            if panel.firstResponder !== note.textView { return false }
        }
        return perform(action)
    }

    @discardableResult
    func perform(_ a: Action) -> Bool {
        guard let note else { return false }
        if note.textView.perform(a) { return true }
        if let i = a.pinIndex { openPinned(i); return true }
        switch a {
        case .newNote: switchTo(NotesLibrary.newID())
        case .browseNotes: showBrowser()
        case .actionPanel: showActions()
        case .togglePin:
            note.saveNow()
            NotesState.shared.togglePin(note.noteID)
            updateNoteTitle(note.title)
        case .deleteNote: deleteCurrent()
        case .duplicateNote:
            let id = NotesLibrary.newID()
            switchTo(id, initialText: note.text)
        case .copyNote:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(note.text, forType: .string)
        case .revealNote:
            note.saveNow()
            NSWorkspace.shared.activateFileViewerSelecting([note.fileURL])
        case .openInNewSticky:
            note.saveNow()
            app?.popOutNote(note.noteID, from: panel)
        case .back:
            guard historyIndex > 0 else { return true }
            historyIndex -= 1
            switchTo(history[historyIndex], record: false)
        case .forward:
            guard historyIndex < history.count - 1 else { return true }
            historyIndex += 1
            switchTo(history[historyIndex], record: false)
        case .nextRecent: cycleRecent(1)
        case .prevRecent: cycleRecent(-1)
        case .zoomIn: NotesState.shared.zoom += 0.1
        case .zoomOut: NotesState.shared.zoom -= 0.1
        case .zoomReset: NotesState.shared.zoom = 1
        case .find: note.showFind()
        case .hideNotes, .toggleNotes, .newNoteGlobal, .toggleAll, .switchStickiesGlobal, .editKeybindings:
            app?.runGlobal(a)
        default: return false
        }
        return true
    }

    func switchTo(_ id: String, initialText: String? = nil, record: Bool = true) {
        guard let note else { return }
        note.load(id, initialText: initialText)
        config.note = id
        app?.persist()
        if record {
            history = Array(history.prefix(historyIndex + 1)) + [id]
            historyIndex = history.count - 1
        }
        updateNoteTitle(note.title)
        panel.makeFirstResponder(note.textView)
    }

    private func newNote(titled title: String) {
        switchTo(NotesLibrary.newID(), initialText: "# \(title)\n\n")
    }

    private func openPinned(_ i: Int) {
        let pins = NotesState.shared.pinned
        guard i < pins.count else { NSSound.beep(); return }
        switchTo(pins[i])
    }

    private func cycleRecent(_ step: Int) {
        guard let note else { return }
        note.saveNow()
        let ids = NotesLibrary.all().map(\.id)
        guard !ids.isEmpty else { return }
        let i = ids.firstIndex(of: note.noteID) ?? (step > 0 ? -1 : ids.count)
        let next = ((i + step) % ids.count + ids.count) % ids.count
        if ids[next] != note.noteID { switchTo(ids[next]) }
    }

    private func deleteCurrent() {
        guard let note else { return }
        let id = note.noteID
        note.discard()
        if FileManager.default.fileExists(atPath: note.fileURL.path) {
            try? FileManager.default.trashItem(at: note.fileURL, resultingItemURL: nil)
        }
        NotesState.shared.unpin(id)
        history.removeAll { $0 == id }
        historyIndex = max(0, min(historyIndex, history.count - 1))
        switchTo(NotesLibrary.all().first?.id ?? NotesLibrary.newID())
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    /// The first line after the title, for the ⌘P list.
    private func preview(_ body: String) -> String {
        let lines = body.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count > 1 else { return lines.isEmpty ? "Empty note" : " " }
        var line = lines[1].trimmingCharacters(in: CharacterSet(charactersIn: "#>-*[] \t"))
        // Plain text: [text](url) → text, and drop ** * ~~ ` <u> markers.
        line = line.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #"</?u>|[*~`]+|(?<!\w)_|_(?!\w)"#, with: "", options: .regularExpression)
        return line
    }

    private func showBrowser() {
        guard let note else { return }
        note.saveNow()
        let notes = NotesLibrary.all()
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pins = NotesState.shared.pinned
        let pinActions: [Action] = [.pinned1, .pinned2, .pinned3, .pinned4, .pinned5, .pinned6, .pinned7, .pinned8, .pinned9]
        var items: [QuickPicker.Item] = []
        for (i, id) in pins.enumerated() {
            guard let n = byID[id] ?? NotesLibrary.info(for: id) else { continue }
            let key = i < pinActions.count ? Keymap.shared.shortcut(pinActions[i]) : ""
            items.append(.init(title: "📌 " + n.title, subtitle: preview(n.body), detail: key, searchText: n.body) { [weak self] in self?.switchTo(id) })
        }
        for n in notes where !pins.contains(n.id) {
            let current = (n.id == note.noteID ? "current · " : "") + (n.id.contains("-conflict-") ? "conflict copy · " : "")
            items.append(.init(title: n.title, subtitle: preview(n.body), detail: current + relative(n.modified), searchText: n.body) { [weak self] in
                self?.switchTo(n.id)
            })
        }
        QuickPicker.shared.present(placeholder: "Search notes…", items: items, over: panel) { [weak self] q in
            q.isEmpty ? nil : .init(title: "Create note “\(q)”", detail: Keymap.shared.shortcut(.newNote)) { self?.newNote(titled: q) }
        }
    }

    private func showActions() {
        let skip: Set<Action> = [.actionPanel, .pinned2, .pinned3, .pinned4, .pinned5, .pinned6, .pinned7, .pinned8, .pinned9]
        let items = Action.allCases.filter { !skip.contains($0) && !$0.isStickyOnly }.map { a in
            QuickPicker.Item(title: a.title, detail: Keymap.shared.combos(a).map(\.display).joined(separator: "  ")) { [weak self] in
                self?.perform(a)
            }
        }
        QuickPicker.shared.present(placeholder: "Search actions…", items: items, over: panel)
    }

    private func setUpWeb(in container: NSView, given: WKWebViewConfiguration?) {
        let cfg = given ?? WKWebViewConfiguration()
        if given == nil, #available(macOS 15.4, *) { cfg.webExtensionController = ExtensionHost.shared.controller }
        let w = WKWebView(frame: container.bounds, configuration: cfg)
        w.autoresizingMask = [.width, .height]
        w.allowsBackForwardNavigationGestures = true
        w.uiDelegate = self
        w.navigationDelegate = self
        w.isInspectable = true  // right-click → Inspect Element, for debugging
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        w.allowsMagnification = true  // trackpad pinch
        w.pageZoom = config.zoom ?? 1
        container.addSubview(w)
        web = w
        panel.keyHandler = { [weak self] e in self?.handleStickyKey(e) ?? false }
        // A window a page opened: WebKit loads it. Otherwise load the saved address.
        if given == nil, let u = URL(string: config.url ?? "") { w.load(URLRequest(url: u)) }
        panel.title = config.url ?? "Web"
        titleObserver = w.observe(\.title) { [weak self] w, _ in
            MainActor.assumeIsolated {
                guard let self, let t = w.title, !t.isEmpty else { return }
                self.panel.title = t
                // A new page title means the page loaded: refresh the switcher picture soon.
                self.thumbnailSoon?.cancel()
                let job = DispatchWorkItem { [weak self] in
                    if let self, self.panel.isVisible, self.panel.alphaValue > 0 { self.captureThumbnail() }
                }
                self.thumbnailSoon = job
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: job)
                // The first page title of a visit names the site in the site list.
                if self.visitNeedsTitle, let u = w.url {
                    self.visitNeedsTitle = false
                    Sites.shared.setTitle(t, for: u)
                }
            }
        }
        // A new site (not every page) counts as a visit, for ranking the site list. Only once you've
        // stayed 3 seconds, so sign-in pages you pass through on the way don't count.
        urlObserver = w.observe(\.url) { [weak self] w, _ in
            MainActor.assumeIsolated {
                guard let self, let u = w.url else { return }
                // A window a page opened (often about:blank first): remember its first real address.
                if self.config.url?.hasPrefix("http") != true, u.scheme?.hasPrefix("http") == true {
                    self.config.url = u.absoluteString
                    self.app?.persist()
                }
                guard let host = Sites.key(for: u), host != self.visitHost else { return }
                self.visitHost = host
                if self.skipFirstVisit || self.config.popup == true { self.skipFirstVisit = false; return }  // sign-in popups aren't visits
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak w] in
                    guard let self, let w, self.visitHost == host else { return }
                    let title = w.title ?? ""
                    Sites.shared.recordVisit(u, title: title)
                    self.visitNeedsTitle = title.isEmpty
                }
            }
        }
    }

    var isWeb: Bool { web != nil }
    var webView: WKWebView? { web }
    var isTerminal: Bool { term != nil }
    var currentURL: URL? { web?.url ?? URL(string: config.url ?? "") }

    /// Name for the switcher and the menu bar list.
    var displayTitle: String {
        let t = panel.title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        return currentURL?.host ?? config.command ?? "Sticky"
    }

    func navigate(to url: URL) {
        guard let w = web else { return }
        w.load(URLRequest(url: url))
        config.url = url.absoluteString
        app?.persist()
    }

    /// Sticky keys (⌃Tab switcher, ⇧⌘W, ⌘T, ⌘L, ⌘D, zoom). Other keys go to the page or terminal.
    private func handleStickyKey(_ e: NSEvent) -> Bool {
        guard let a = Keymap.shared.localAction(for: e, in: .stickies) else { return false }
        switch a {
        case .switchStickies: app?.switchStickies(back: false, holding: e.modifierFlags)
        case .switchStickiesBack: app?.switchStickies(back: true, holding: e.modifierFlags)
        case .closeSticky: app?.closeForGood(self)
        case .newWebSticky: app?.showSiteLauncher(over: panel, into: nil)
        case .openSiteHere:
            guard isWeb else { return false }
            app?.showSiteLauncher(over: panel, into: self)
        case .saveSite:
            guard let w = web, let u = w.url else { return false }
            let saved = Sites.shared.toggleSaved(u, title: w.title ?? "")
            flash(saved ? "Saved to your sites" : "Removed from your sites")
        case .zoomIn, .zoomOut, .zoomReset:
            guard let w = web else { return false }
            let steps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
            let now = w.pageZoom
            switch a {
            case .zoomIn: w.pageZoom = steps.first { $0 > now + 0.01 } ?? now
            case .zoomOut: w.pageZoom = steps.last { $0 < now - 0.01 } ?? now
            default: w.pageZoom = 1; w.magnification = 1
            }
            config.zoom = Double(w.pageZoom)
            app?.persist()
        default: return false
        }
        return true
    }

    /// A short message at the top of the sticky that fades out.
    func flash(_ text: String) {
        guard let container = panel.contentView else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.sizeToFit()
        let pill = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 28, height: 30))
        pill.material = .hudWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 15
        label.frame.origin = NSPoint(x: 14, y: (30 - label.frame.height) / 2)
        pill.addSubview(label)
        pill.frame.origin = NSPoint(x: (container.bounds.width - pill.frame.width) / 2, y: container.bounds.height - 64)
        pill.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        container.addSubview(pill)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; pill.animator().alphaValue = 0 },
                                                 completionHandler: { pill.removeFromSuperview() })
        }
    }

    /// Takes a small picture of the sticky for the ⌃Tab switcher.
    func captureThumbnail(_ done: (() -> Void)? = nil) {
        if let w = web {
            let c = WKSnapshotConfiguration()
            c.snapshotWidth = 320
            w.takeSnapshot(with: c) { [weak self] img, _ in
                MainActor.assumeIsolated {
                    if let img { self?.thumbnail = img }
                    done?()
                }
            }
        } else if let v = term ?? panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            let img = NSImage(size: v.bounds.size)
            img.addRepresentation(rep)
            thumbnail = img
            done?()
        } else {
            done?()
        }
    }

    /// Is a program (not just the shell prompt) running in this terminal?
    var hasRunningProgram: Bool {
        guard let t = term, t.process.running else { return false }
        var pids = [pid_t](repeating: 0, count: 64)
        let n = proc_listchildpids(t.process.shellPid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return n > 0
    }

    /// Showing on screen (not hidden, and not in the middle of hiding).
    var isShowing: Bool { panel.isVisible && config.hidden != true }

    /// Moves and sizes the sticky (hidden or not), and remembers it.
    func setFrame(_ f: CGRect) {
        panel.setFrame(f, display: false)
        config.frame = f
    }

    /// Hides the sticky. It keeps running, and ⌃Tab or the menu bar brings it back.
    func hide() {
        guard panel.isVisible else { return }
        note?.saveNow()
        config.hidden = true
        app?.persist()
        if isWeb {
            // Looks hidden right away, but stays on screen until the picture is taken:
            // a web view that's off screen can't draw one.
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            var done = false
            let finish = { [weak self] in
                guard let self, !done else { return }
                done = true
                self.panel.orderOut(nil)
                self.panel.ignoresMouseEvents = false
            }
            captureThumbnail(finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: finish)
        } else {
            captureThumbnail()
            panel.orderOut(nil)
        }
    }

    func show() {
        if config.hidden == true { config.hidden = nil; app?.persist() }
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        panel.makeKey()
        if let t = term { panel.makeFirstResponder(t) }
        if let w = web { panel.makeFirstResponder(w) }
        if let n = note { panel.makeFirstResponder(n.textView) }
        updateAlpha()
    }

    func reload() { web?.reload() }

    private func updateAlpha() {
        guard config.hidden != true else { return }  // mid-hide: stay invisible
        let solid = hovering || panel.isKeyWindow
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = solid ? 1.0 : Self.fadedAlpha
        }
    }

    private func saveFrame() {
        config.frame = panel.frame
        app?.stackMoved(self)  // the rest of the stack moves with it
        app?.persist()
    }

    // WKUIDelegate: a page asks for a new window (a link with target="_blank", or window.open).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let app else { return nil }
        let url = navigationAction.request.url
        if let u = url, !Self.opensInSticky(u) { NSWorkspace.shared.open(u); return nil }  // mailto:, zoommtg:, …
        var c = StickyConfig(kind: .web, url: url?.absoluteString)
        if windowFeatures.width != nil || windowFeatures.height != nil {
            // A sized popup, like "Sign in with Google": its own small sticky over this one, until the page closes it.
            // It's a real window, so the sign-in page can talk back to the page that opened it.
            c.popup = true
            var f = CGRect(x: 0, y: 0, width: windowFeatures.width?.doubleValue ?? 480, height: (windowFeatures.height?.doubleValue ?? 640) + 28)
            f.origin = NSPoint(x: panel.frame.midX - f.width / 2, y: panel.frame.maxY - f.height - 30)
            if let s = panel.screen?.visibleFrame {
                f.origin.x = min(max(f.origin.x, s.minX), s.maxX - f.width)
                f.origin.y = min(max(f.origin.y, s.minY), s.maxY - f.height)
            }
            c.frame = f
            return app.open(c, webConfig: configuration).webView
        }
        // A link that opens a new tab: it opens on top of this sticky's stack. ⌘W goes back.
        c.frame = panel.frame
        let s = app.open(c, show: false, webConfig: configuration)
        app.swap(s, into: self)
        return s.webView
    }

    /// Web pages open in stickies. Other links (mail, Zoom, App Store) go to their own apps.
    static func opensInSticky(_ u: URL) -> Bool {
        ["http", "https", "about", "blob", "data", "file"].contains(u.scheme?.lowercased() ?? "")
    }

    // WKNavigationDelegate: ⌘-click or middle-click a link opens it on top of the stack, like a new tab.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // (Not a window that just opened: its first load can carry the same ⌘ click.)
        if navigationAction.navigationType == .linkActivated, webView.backForwardList.currentItem != nil,
           navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2,
           let u = navigationAction.request.url, Self.opensInSticky(u), let app {
            decisionHandler(.cancel)
            let s = app.open(StickyConfig(kind: .web, url: u.absoluteString, frame: panel.frame), show: false)
            app.swap(s, into: self)
            return
        }
        decisionHandler(.allow)
    }

    // The page closed its own window (window.close), like a sign-in popup when you're done.
    func webViewDidClose(_ webView: WKWebView) {
        if webView === web { panel.close() }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.beginSheetModal(for: panel) { completionHandler($0 == .OK ? p.urls : nil) }
    }

    // NSWindowDelegate
    func windowDidBecomeKey(_ n: Notification) {
        updateAlpha()
        if inNotesGroup { app?.noteBecameKey(self) } else { lastFocused = Date(); app?.persist() }
    }
    func windowDidResignKey(_ n: Notification) {
        updateAlpha()
        if !inNotesGroup, panel.isVisible { captureThumbnail() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Red button / ⌘W only hides stickies (web, terminal, note stickies). ⇧⌘W closes them for good.
        // In a stack, only the top one hides, and the one under it shows.
        if !inNotesGroup { app?.dismiss(self); return false }
        guard app?.shouldHideInsteadOfClose(self) == true else { return true }
        note?.saveNow()
        panel.orderOut(nil)
        return false
    }
    func windowDidMove(_ n: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ n: Notification) { saveFrame() }
    func windowWillClose(_ n: Notification) {
        if let t = term, t.process.running { t.process.terminate() }
        note?.saveNow()
        app?.remove(self)
    }

    // LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        if !title.isEmpty { panel.title = title }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { self.panel.close() }
    }
}

// MARK: - App

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var stickies: [StickyController] = []
    private var hotKeyRefs: [EventHotKeyRef] = []
    private let globalActions: [Action] = Action.allCases.filter(\.isGlobal)

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
        buildMainMenu()
        buildStatusMenu()
        installHotKeyHandler()
        registerGlobalHotKeys()
        SyncEngine.shared.start()
        NotificationCenter.default.addObserver(forName: .stickySyncStatus, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncStatusItem?.title = SyncEngine.shared.statusText }
        }
        Keymap.shared.onChange = { [weak self] in
            self?.registerGlobalHotKeys()
            self?.buildStatusMenu()
            if let p = Keymap.shared.problems.first { NSSound.beep(); print("Keybindings: \(p)") }
        }
        enableLoginOnFirstRun()

        // Load extensions first, so web stickies get them from the first page load.
        Task { @MainActor in
            if #available(macOS 15.4, *) {
                await ExtensionHost.shared.loadAll()
                buildStatusMenu()
                // Debug: STICKY_DEBUG_POPUP=1 opens the first extension's popup on launch.
                if ProcessInfo.processInfo.environment["STICKY_DEBUG_POPUP"] != nil,
                   let ctx = ExtensionHost.shared.contexts.first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { ExtensionHost.shared.openPopup(ctx) }
                }
            }
            // Stickies come back where they were. The notes window stays hidden until ⌃⌘B,
            // like Raycast Notes.
            loading = true  // don't save (or tidy up stacks) until every sticky is back
            for c in Self.upgradeStacks(Store.load()) {
                open(c, show: (c.kind != .note || c.noteSticky == true) && c.hidden != true, restoring: true)
            }
            loading = false
            persist()
            if stickies.isEmpty { newClaudeHere(folder: NSHomeDirectory() + "/Documents") }
            // Debug: STICKY_DEBUG_BROWSE=1 opens the ⌘P note switcher on launch.
            if ProcessInfo.processInfo.environment["STICKY_DEBUG_BROWSE"] != nil, let n = noteStickies.first {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    n.show()
                    n.perform(.browseNotes)
                    if let path = ProcessInfo.processInfo.environment["STICKY_DEBUG_SNAPSHOT"] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { QuickPicker.shared.snapshot(to: path) }
                    }
                }
            }
        }
    }

    /// One time, from before stacks: stickies swapped into the exact same spot become one stack.
    private static func upgradeStacks(_ list: [StickyConfig]) -> [StickyConfig] {
        let key = "didUpgradeStacks"
        guard !UserDefaults.standard.bool(forKey: key) else { return list }
        UserDefaults.standard.set(true, forKey: key)
        var list = list
        let candidates = list.indices.filter { (list[$0].kind != .note || list[$0].noteSticky == true) && list[$0].frame != nil }
        let bySpot = Dictionary(grouping: candidates) { "\(list[$0].frame!)" }
        for (_, group) in bySpot where group.count > 1 && group.contains(where: { list[$0].hidden == true }) {
            let id = UUID()
            group.forEach { list[$0].stack = id }
        }
        return list
    }

    // Menu bar icon
    private func buildStatusMenu() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Sticky")
        }
        let k = Keymap.shared
        let m = NSMenu()
        m.delegate = self  // fills in the live list of stickies each time the menu opens
        // Notes and stickies are separate things: each has its own section and its own show/hide.
        m.addItem(.sectionHeader(title: "Notes"))
        add(m, "Show / Hide Notes   \(k.shortcut(.toggleNotes))", #selector(toggleNotes))
        add(m, "New Note   \(k.shortcut(.newNoteGlobal))", #selector(newNote))
        add(m, "Open Note File…", #selector(openNote))
        add(m, "Open Notes Folder", #selector(revealNotes))
        if SyncEngine.shared.isConfigured {
            let status = NSMenuItem(title: SyncEngine.shared.statusText, action: nil, keyEquivalent: "")
            status.isEnabled = false
            m.addItem(status)
            syncStatusItem = status
            add(m, "Sync Notes Now", #selector(syncNow))
            add(m, "Copy Phone Sync Key", #selector(copyPhoneKey))
            add(m, "Open Notes on the Web", #selector(openWebNotes))
        }
        m.addItem(.separator())
        m.addItem(.sectionHeader(title: "Stickies"))
        stickiesToggleItem = add(m, "Show / Hide Stickies   \(k.shortcut(.toggleAll))", #selector(toggleAll))
        add(m, "New Claude Code Sticky (web)", #selector(newClaudeCodeWeb))
        add(m, "New Claude CLI Sticky…", #selector(newClaude))
        add(m, "New Terminal Sticky…", #selector(newTerminal))
        add(m, "New Web Sticky…   \(k.shortcut(.newWebSticky))", #selector(newWeb))
        add(m, "New Note Sticky", #selector(newNoteSticky))
        if #available(macOS 15.4, *) {
            m.addItem(.separator())
            let host = ExtensionHost.shared
            host.anchor = statusItem.button
            m.addItem(.sectionHeader(title: "Web Extensions"))
            for ctx in host.contexts where host.hasPopup(ctx) {
                let item = NSMenuItem(title: "\(host.name(ctx))…", action: #selector(openExtension(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ctx
                item.image = ctx.webExtension.icon(for: NSSize(width: 16, height: 16))
                m.addItem(item)
            }
            add(m, "Add Extension…", #selector(addExtension))
            add(m, "Open Extensions Folder", #selector(revealExtensions))
        }
        m.addItem(.separator())
        add(m, "Edit Keybindings…", #selector(editKeybindings))
        add(m, "Open Saved Stickies File", #selector(revealStore))
        loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        m.addItem(loginItem)
        refreshLoginItem()
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Sticky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    @discardableResult
    private func add(_ m: NSMenu, _ title: String, _ sel: Selector) -> NSMenuItem {
        let item = m.addItem(withTitle: title, action: sel, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: Managing web and terminal stickies

    private weak var stickiesToggleItem: NSMenuItem?
    private static let listTag = 9001

    /// Web, terminal and note stickies: everything except the notes window.
    private var otherStickies: [StickyController] { stickies.filter { !$0.inNotesGroup } }

    /// The menu bar list: one item per sticky, checked when it's showing. Hold ⌥ to close one.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.filter { $0.tag == Self.listTag }.forEach(menu.removeItem)
        let list = otherStickies
        guard !list.isEmpty, let anchor = stickiesToggleItem, var i = menu.items.firstIndex(of: anchor) else { return }
        func put(_ item: NSMenuItem) { item.tag = Self.listTag; i += 1; menu.insertItem(item, at: i) }
        // A stack is listed together: the one on top, then the ones behind it, indented.
        var ordered: [StickyController] = []
        for s in list where !ordered.contains(where: { $0 === s }) {
            guard s.config.stack != nil else { ordered.append(s); continue }
            let all = ([s] + mates(of: s)).sorted { $0.isShowing != $1.isShowing ? $0.isShowing : $0.lastFocused > $1.lastFocused }
            ordered += all
        }
        var placed: [StickyController] = []
        for s in ordered {
            let behind = s.config.stack != nil && placed.contains { $0.config.stack == s.config.stack }
            placed.append(s)
            let full = s.displayTitle
            let name = full.count > 42 ? String(full.prefix(41)) + "…" : full
            let item = NSMenuItem(title: name, action: #selector(menuToggleSticky(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s
            item.state = s.panel.isVisible ? .on : .off
            item.image = NSImage(systemSymbolName: s.symbolName, accessibilityDescription: nil)
            item.indentationLevel = behind ? 1 : 0
            put(item)
            let close = NSMenuItem(title: "Close “\(name)” for Good", action: #selector(menuCloseSticky(_:)), keyEquivalent: "")
            close.target = self
            close.representedObject = s
            close.keyEquivalentModifierMask = .option
            close.isAlternate = true
            close.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            close.indentationLevel = item.indentationLevel
            put(close)
        }
        let hint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hint.attributedTitle = NSAttributedString(string: "Click to show or hide. Hold ⌥ to close one.", attributes: [
            .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        hint.isEnabled = false
        put(hint)
        put(.separator())
    }

    @objc func menuToggleSticky(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? StickyController else { return }
        if s.panel.isVisible { dismiss(s) } else { raise(s) }
    }

    @objc func menuCloseSticky(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? StickyController else { return }
        DispatchQueue.main.async { self.closeForGood(s) }  // after the menu closes
    }

    /// ⌃Tab / ⌥Tab: most recently used sticky first, hidden ones included.
    func switchStickies(back: Bool, holding mods: NSEvent.ModifierFlags) {
        let list = otherStickies.sorted { $0.lastFocused > $1.lastFocused }
        StickySwitcher.shared.step(back: back, holding: mods, stickies: list)
    }

    // MARK: Stacks
    // Stickies can share one spot, like tabs. One shows; the rest wait behind it, hidden but still running.
    // ⌃Tab (let go) and links that open a new window put a sticky on top. ⌘W takes the top one off.

    /// The other stickies in s's stack, most recently used first.
    func mates(of s: StickyController) -> [StickyController] {
        guard let id = s.config.stack else { return [] }
        return otherStickies.filter { $0 !== s && $0.config.stack == id }.sorted { $0.lastFocused > $1.lastFocused }
    }

    /// Shows s on top of its stack, in the stack's spot. The one that was on top waits behind it.
    func raise(_ s: StickyController) {
        let showing = mates(of: s).filter(\.isShowing)
        if let top = showing.first { s.setFrame(top.panel.frame) }
        s.show()
        showing.forEach { $0.hide() }
        persist()
    }

    /// ⌃Tab (let go), or a link that opens a new window: s takes out's spot, on top of out's stack.
    func swap(_ s: StickyController, into out: StickyController) {
        if s.config.stack == nil || s.config.stack != out.config.stack {
            leaveStack(s)
            let id = out.config.stack ?? UUID()
            out.config.stack = id
            s.config.stack = id
        }
        s.setFrame(out.panel.frame)
        s.show()
        if out !== s { out.hide() }
        persist()
    }

    /// Takes s out of its stack. If it was the one showing, the next one in the stack shows in its spot.
    private func leaveStack(_ s: StickyController) {
        let next = s.isShowing ? mates(of: s).first : nil
        s.config.stack = nil
        if let next { next.setFrame(s.panel.frame); next.show() }
    }

    /// ⌘W, the red button, or clicking a showing sticky in the menu: hides s (it keeps running).
    /// In a stack, only s comes off the top, and the one under it shows.
    func dismiss(_ s: StickyController) {
        guard s.panel.isVisible else { return }
        leaveStack(s)
        s.hide()
        persist()
    }

    /// ⌃Tab, Return: s shows on its own. If it was waiting in a stack, it leaves the stack.
    func showSeparately(_ s: StickyController) {
        if !s.isShowing {
            s.config.stack = nil
            // Stacked stickies share a spot, so nudge it over instead of opening right on top.
            if otherStickies.contains(where: { $0 !== s && $0.isShowing && $0.panel.frame == s.panel.frame }) {
                s.setFrame(s.panel.frame.offsetBy(dx: 40, dy: -40))
            }
        }
        s.show()
        persist()
    }

    /// The stack moves and resizes together.
    func stackMoved(_ s: StickyController) {
        guard s.isShowing else { return }
        for m in mates(of: s) where m.panel.frame != s.panel.frame { m.setFrame(s.panel.frame) }
    }

    /// ⇧⌘W, the switcher's W key, or ⌥ in the menu. Asks first if a program is still running.
    func closeForGood(_ s: StickyController) {
        if s.hasRunningProgram {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Close “\(s.displayTitle)”?"
            a.informativeText = "A program is still running in it. Closing the sticky stops it. To keep it running, hide it instead (⌘W)."
            a.addButton(withTitle: "Close")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        s.panel.close()
    }

    /// ⌘T / menu: pick a saved or past site, or type a new one. ⌘L opens it in the same sticky.
    func showSiteLauncher(over parent: NSWindow?, into target: StickyController?) {
        let go: (URL) -> Void = { [weak self, weak target] url in
            if let target { target.navigate(to: url) } else { self?.open(StickyConfig(kind: .web, url: url.absoluteString)) }
        }
        QuickPicker.shared.present(
            placeholder: target == nil ? "Open a site in a new sticky…" : "Open a site in this sticky…",
            items: [], over: parent, rank: { q in Sites.shared.pickerItems(for: q, open: go) })
    }

    // Hidden main menu so ⌘C / ⌘V / ⌘W / ⌘R work inside stickies.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Sticky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Reload Web Page", action: #selector(reloadKey), keyEquivalent: "r").target = self
        winItem.submenu = win
        NSApp.mainMenu = main
    }

    // Global hotkeys from the keymap. Uses Carbon, so no Accessibility permission needed.
    private func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = Int(hk.id)
            let me = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.hotKeyPressed(id) } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func registerGlobalHotKeys() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs = []
        for (i, a) in globalActions.enumerated() {
            for combo in Keymap.shared.combos(a) {
                var ref: EventHotKeyRef?
                RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonMods,
                                    EventHotKeyID(signature: OSType(0x5354_4B59), id: UInt32(i)),
                                    GetApplicationEventTarget(), 0, &ref)
                if let ref { hotKeyRefs.append(ref) }
            }
        }
    }

    private func hotKeyPressed(_ i: Int) {
        guard i < globalActions.count else { return }
        runGlobal(globalActions[i])
    }

    func runGlobal(_ a: Action) {
        switch a {
        case .toggleNotes: toggleNotes()
        case .newNoteGlobal: newNote()
        case .toggleAll: toggleAll()
        case .switchStickiesGlobal: switchStickies(back: false, holding: NSEvent.modifierFlags)
        case .hideNotes: hideNotes()
        case .editKeybindings: editKeybindings()
        default: break
        }
    }

    private var noteStickies: [StickyController] { stickies.filter(\.inNotesGroup) }
    private weak var lastNote: StickyController?

    /// Like Raycast Notes: one hotkey shows the notes window, or hides it if it's in front.
    @objc func toggleNotes() {
        let notes = noteStickies
        if notes.isEmpty {
            open(StickyConfig(kind: .note, note: NotesLibrary.all().first?.id))
            return
        }
        if notes.contains(where: { $0.panel.isKeyWindow }) {
            hideNotes()
        } else {
            notes.forEach { $0.show() }
            (lastNote ?? notes.last)?.show()
        }
    }

    func hideNotes() {
        noteStickies.forEach { $0.panel.orderOut(nil) }
    }

    func noteBecameKey(_ s: StickyController) { lastNote = s }

    @objc func editKeybindings() {
        if let existing = stickies.first(where: { $0.config.note == Keymap.file.path }) {
            existing.show()
        } else {
            open(StickyConfig(kind: .note, note: Keymap.file.path))
        }
    }

    // Actions
    @objc func newClaude() {
        guard let folder = pickFolder() else { return }
        newClaudeHere(folder: folder)
    }

    private func newClaudeHere(folder: String) {
        open(StickyConfig(kind: .terminal, command: "claude", folder: folder))
    }

    @objc func newTerminal() {
        guard let cmd = ask("Command to run", placeholder: "e.g. python3, htop, npm run dev", value: "zsh"),
              !cmd.isEmpty,
              let folder = pickFolder() else { return }
        open(StickyConfig(kind: .terminal, command: cmd, folder: folder))
    }

    @objc func newNote() {
        if let s = lastNote ?? noteStickies.last {
            s.show()
            s.perform(.newNote)
        } else {
            open(StickyConfig(kind: .note))
        }
    }

    @objc func openNote() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.directoryURL = NotesFolder.url
        p.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for u in p.urls {
            let inFolder = u.deletingLastPathComponent().standardizedFileURL == NotesFolder.url.standardizedFileURL
            open(StickyConfig(kind: .note, note: inFolder ? u.lastPathComponent : u.path))
        }
    }

    private weak var syncStatusItem: NSMenuItem?

    @objc func syncNow() { SyncEngine.shared.syncSoon(after: 0) }

    @objc func copyPhoneKey() {
        SyncEngine.shared.copyKeyForPhone()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Sync key copied"
        a.informativeText = "On your iPhone, open Sticky Notes and paste it (Universal Clipboard). The key is cleared from the clipboard in 2 minutes."
        a.runModal()
    }

    @objc func openWebNotes() {
        if let s = SyncEngine.shared.config?.url, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    @objc func openExtension(_ sender: NSMenuItem) {
        guard #available(macOS 15.4, *), let ctx = sender.representedObject as? WKWebExtensionContext else { return }
        // Wait for the menu to close, then show the popup under the menu bar icon.
        DispatchQueue.main.async { ExtensionHost.shared.openPopup(ctx) }
    }

    @objc func addExtension() {
        guard #available(macOS 15.4, *) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowedContentTypes = [.folder, .zip, UTType(filenameExtension: "crx") ?? .data]
        p.message = "Pick an unpacked extension folder, a .zip, or a .crx"
        p.prompt = "Add Extension"
        p.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard p.runModal() == .OK, let url = p.url else { return }
        Task { @MainActor in
            let problem = await ExtensionHost.shared.install(from: url)
            buildStatusMenu()
            let alert = NSAlert()
            if let problem {
                alert.messageText = "Couldn't add the extension"
                alert.informativeText = problem
            } else {
                alert.messageText = "Extension added"
                alert.informativeText = "Reload open web stickies (⌘R) to use it."
            }
            alert.runModal()
        }
    }

    @objc func revealExtensions() { NSWorkspace.shared.open(ExtensionsFolder.url) }

    @objc func revealNotes() { NSWorkspace.shared.open(NotesFolder.url) }

    @objc func newClaudeCodeWeb() {
        open(StickyConfig(kind: .web, url: "https://claude.ai/code"))
    }

    @objc func newWeb() { showSiteLauncher(over: nil, into: nil) }

    /// A new, empty note as a sticky. ⌘P inside it switches to any other note.
    @objc func newNoteSticky() { open(StickyConfig(kind: .note, noteSticky: true)) }

    /// ⇧⌘N in a note: shows that note as its own sticky, next to the window you're in.
    func popOutNote(_ id: String, from window: NSWindow) {
        var c = StickyConfig(kind: .note, note: id, noteSticky: true)
        let size = NSSize(width: 320, height: 340)
        var origin = NSPoint(x: window.frame.maxX + 12, y: window.frame.maxY - size.height)
        if let f = window.screen?.visibleFrame {
            if origin.x + size.width > f.maxX { origin.x = window.frame.minX - size.width - 12 }
            origin.x = min(max(origin.x, f.minX), f.maxX - size.width)
            origin.y = min(max(origin.y, f.minY), f.maxY - size.height)
        }
        c.frame = CGRect(origin: origin, size: size)
        open(c)
    }

    /// Shows or hides the terminal and web stickies. Never touches the notes window (that's ⌃⌘B).
    @objc func toggleAll() {
        let others = otherStickies
        if others.contains(where: { $0.panel.isVisible }) {
            others.forEach { $0.panel.orderOut(nil) }
        } else {
            // Ones you hid on their own stay hidden, unless that's all of them (then the top of each stack).
            let wanted = others.filter { $0.config.hidden != true }
            let tops = others.filter { s in mates(of: s).allSatisfy { $0.lastFocused < s.lastFocused } }
            (wanted.isEmpty ? tops : wanted).forEach { $0.show() }
        }
    }

    /// Closing the last notes window only hides it, so ⌃⌘B brings it back in the same spot.
    func shouldHideInsteadOfClose(_ s: StickyController) -> Bool {
        // Only for notes from the notes folder (not, say, the keybindings file).
        let isLibraryNote = { (c: StickyController) in c.inNotesGroup && !(c.config.note ?? "").hasPrefix("/") }
        return isLibraryNote(s) && stickies.filter(isLibraryNote).count == 1
    }

    // Open at login (macOS login items). Turned on once on first launch; the menu toggles it.
    private var loginItem: NSMenuItem!

    private func enableLoginOnFirstRun() {
        let key = "didSetUpLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: key)
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        refreshLoginItem()
    }

    @objc func revealStore() { NSWorkspace.shared.activateFileViewerSelecting([Store.file]) }

    @objc func reloadKey() {
        stickies.first { $0.panel.isKeyWindow }?.reload()
    }

    // Bookkeeping
    @discardableResult
    func open(_ c: StickyConfig, show: Bool = true, restoring: Bool = false, webConfig: WKWebViewConfiguration? = nil) -> StickyController {
        let s = StickyController(config: c, app: self, cascade: stickies.count % 8, restoring: restoring, webConfig: webConfig)
        if c.kind != .note || c.noteSticky == true {
            if !restoring { s.lastFocused = Date() }
            else if c.used == nil { s.lastFocused = Date.distantPast.addingTimeInterval(Double(stickies.count)) }
        }
        stickies.append(s)
        if show { s.show() }
        persist()
        return s
    }

    /// A sticky closed for good. If it was on top of a stack, the next one shows in its spot.
    func remove(_ s: StickyController) {
        let next = s.isShowing ? mates(of: s).first : nil
        stickies.removeAll { $0 === s }
        if let next { next.setFrame(s.panel.frame); next.show() }
        persist()
    }

    private var loading = false

    func persist() {
        guard !loading else { return }
        // A stack of one is just a sticky.
        var count: [UUID: Int] = [:]
        for s in stickies { if let id = s.config.stack { count[id, default: 0] += 1 } }
        for s in stickies where s.config.stack.map({ count[$0, default: 0] < 2 }) == true { s.config.stack = nil }
        Store.save(stickies.filter { $0.config.popup != true }.map(\.config))
    }

    // Dialogs
    private func ask(_ title: String, placeholder: String, value: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pickFolder() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Use This Folder"
        p.message = "Pick the folder this sticky runs in"
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Documents")
        return p.runModal() == .OK ? p.url?.path : nil
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
