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

@MainActor final class StickyController: NSObject, NSWindowDelegate, LocalProcessTerminalViewDelegate, WKUIDelegate {
    static let fadedAlpha: CGFloat = 0.4

    var config: StickyConfig
    let panel: StickyPanel
    weak var app: AppDelegate?
    private var hovering = false
    private var term: LocalProcessTerminalView?
    private var web: WKWebView?
    private var titleObserver: NSKeyValueObservation?
    private var popups: [NSPanel] = []
    private var note: NoteEditor?

    init(config: StickyConfig, app: AppDelegate, cascade: Int) {
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
            panel.setContentSize(NSSize(width: 380, height: 440))
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

        switch config.kind {
        case .terminal: setUpTerminal(in: container)
        case .web: setUpWeb(in: container)
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
        let name = config.note ?? "note-\(config.id.uuidString.prefix(8).lowercased()).md"
        config.note = name
        let file = name.hasPrefix("/") ? URL(fileURLWithPath: name) : NotesFolder.url.appendingPathComponent(name)
        let editor = NoteEditor(fileURL: file, frame: container.bounds)
        editor.onTitle = { [weak self] t in self?.panel.title = t }
        container.addSubview(editor.scroll)
        panel.title = editor.title
        note = editor
    }

    private func setUpWeb(in container: NSView) {
        let w = WKWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        w.autoresizingMask = [.width, .height]
        w.allowsBackForwardNavigationGestures = true
        w.uiDelegate = self
        w.isInspectable = true  // right-click → Inspect Element, for debugging
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        container.addSubview(w)
        web = w
        if let u = URL(string: config.url ?? "") { w.load(URLRequest(url: u)) }
        panel.title = config.url ?? "Web"
        titleObserver = w.observe(\.title) { [weak self] w, _ in
            if let t = w.title, !t.isEmpty { self?.panel.title = t }
        }
    }

    func show() {
        panel.orderFrontRegardless()
        panel.makeKey()
        if let t = term { panel.makeFirstResponder(t) }
        if let w = web { panel.makeFirstResponder(w) }
        if let n = note { panel.makeFirstResponder(n.textView) }
        updateAlpha()
    }

    func reload() { web?.reload() }

    private func updateAlpha() {
        let solid = hovering || panel.isKeyWindow
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = solid ? 1.0 : Self.fadedAlpha
        }
    }

    private func saveFrame() {
        config.frame = panel.frame
        app?.persist()
    }

    // WKUIDelegate: open sign-in popups in the same sticky, allow file uploads.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Real popup window, so sign-in pages can talk back to the page that opened them.
        let pop = StickyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        pop.level = .floating
        pop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pop.hidesOnDeactivate = false
        pop.isReleasedWhenClosed = false
        let child = WKWebView(frame: pop.contentView!.bounds, configuration: configuration)
        child.autoresizingMask = [.width, .height]
        child.customUserAgent = webView.customUserAgent
        child.uiDelegate = self
        child.isInspectable = true
        pop.contentView = child
        pop.center()
        popups.append(pop)
        pop.orderFrontRegardless()
        pop.makeKey()
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let pop = popups.first(where: { $0.contentView === webView }) else { return }
        pop.close()
        popups.removeAll { $0 === pop }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.beginSheetModal(for: panel) { completionHandler($0 == .OK ? p.urls : nil) }
    }

    // NSWindowDelegate
    func windowDidBecomeKey(_ n: Notification) { updateAlpha() }
    func windowDidResignKey(_ n: Notification) { updateAlpha() }
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

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var stickies: [StickyController] = []
    private var hidden = false
    private var hotKeyRef: EventHotKeyRef?
    private var noteHotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
        buildMainMenu()
        buildStatusMenu()
        registerHotKey()
        enableLoginOnFirstRun()

        for c in Store.load() { open(c) }
        if stickies.isEmpty { newClaudeHere(folder: NSHomeDirectory() + "/Documents") }
    }

    // Menu bar icon
    private func buildStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Sticky")
        let m = NSMenu()
        add(m, "New Note   ⌃⌥N", #selector(newNote))
        add(m, "Open Note…", #selector(openNote))
        add(m, "Open Notes Folder", #selector(revealNotes))
        m.addItem(.separator())
        add(m, "New Claude Code Sticky (web)", #selector(newClaudeCodeWeb))
        add(m, "New Claude CLI Sticky…", #selector(newClaude))
        add(m, "New Terminal Sticky…", #selector(newTerminal))
        add(m, "New Web Sticky…", #selector(newWeb))
        m.addItem(.separator())
        add(m, "Show / Hide All   ⌃⌥Space", #selector(toggleAll))
        add(m, "Open Saved Stickies File", #selector(revealStore))
        loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        m.addItem(loginItem)
        refreshLoginItem()
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Sticky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    private func add(_ m: NSMenu, _ title: String, _ sel: Selector) {
        m.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self
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

    // Global hotkey ⌃⌥Space. Uses Carbon, so no Accessibility permission needed.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            let me = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { if id == 2 { me.newNote() } else { me.toggleAll() } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: OSType(0x5354_4B59), id: 1),
                            GetApplicationEventTarget(), 0, &hotKeyRef)
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: OSType(0x5354_4B59), id: 2),
                            GetApplicationEventTarget(), 0, &noteHotKeyRef)
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
        open(StickyConfig(kind: .note))
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

    @objc func revealNotes() { NSWorkspace.shared.open(NotesFolder.url) }

    @objc func newClaudeCodeWeb() {
        open(StickyConfig(kind: .web, url: "https://claude.ai/code"))
    }

    @objc func newWeb() {
        guard var url = ask("Website", placeholder: "e.g. chatgpt.com", value: "https://"),
              !url.isEmpty, url != "https://" else { return }
        if !url.contains("://") { url = "https://" + url }
        open(StickyConfig(kind: .web, url: url))
    }

    @objc func toggleAll() {
        hidden.toggle()
        for s in stickies { hidden ? s.panel.orderOut(nil) : s.show() }
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
    func open(_ c: StickyConfig) {
        let s = StickyController(config: c, app: self, cascade: stickies.count % 8)
        stickies.append(s)
        hidden = false
        s.show()
        persist()
    }

    func remove(_ s: StickyController) {
        stickies.removeAll { $0 === s }
        persist()
    }

    func persist() { Store.save(stickies.map(\.config)) }

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
