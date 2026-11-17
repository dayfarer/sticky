// The chat inside a chat sticky: the page, the chat's file, and (only after you send) a claude process.
//
// The page (ChatPage) only draws. This keeps it in step with the chat's .jsonl, read on a background queue as
// it grows, plus what isn't on file yet: messages you just sent, the reply being written, and permission cards.
// Claude starts on your first message, so restoring ten chat stickies doesn't start ten claudes.
import AppKit
import WebKit

/// The chat inside a chat sticky: the page, the chat's file, and (only after you send) a claude process.
@MainActor final class ChatView: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    /// The chat's id (its file is <id>.jsonl). nil for a new chat until you send.
    private(set) var session: String?
    /// Where the chat runs: the folder the chat itself says, else the one it was opened with.
    var folder: String { meta.cwd ?? baseFolder }
    /// Without the busy dot. The Claude app's title (it follows renames there), else the file's own, else the one
    /// the chat was opened with.
    var title: String {
        if let s = session, let t = ChatIndex.shared.appTitle(s), !t.isEmpty { return Self.oneLine(t, 120) }
        if let t = meta.title, !t.isEmpty { return Self.oneLine(t, 120) }
        if let t = givenTitle { return t }
        if let p = meta.firstPrompt, !p.isEmpty { return Self.oneLine(p, 60) }
        return "New chat"
    }
    /// A turn is running, a permission card is waiting, or claude runs a background task (a dev server, say).
    var isBusy: Bool { running || !cards.isEmpty || (process != nil && bgTasks > 0) }

    var onTitle: ((String) -> Void)?       // the sticky's title should change ("● " in front while running)
    var onSession: ((String) -> Void)?     // the chat's id changed (a new chat got its id, a copy, /clear)
    var onSettings: ((_ mode: String?, _ model: String?) -> Void)?  // you changed the mode or model
    var onActivity: (() -> Void)?          // new content (refresh the switcher picture soon)
    var onOpenURL: ((URL) -> Void)?

    // MARK: State

    private enum Part: CaseIterable { case items, pending, ghost, perms, status }

    private static let modes: [[String: Any]] = [
        ["value": "default", "label": "Ask first"], ["value": "acceptEdits", "label": "Accept edits"],
        ["value": "plan", "label": "Plan"], ["value": "auto", "label": "Auto"],
    ]
    private static let safeModes: Set<String> = ["default", "acceptEdits", "plan", "auto"]
    /// The models claude offers. Known once a claude has started, then kept for the app session.
    private static var models: [(value: String, label: String)] = []

    private let baseFolder: String
    private let givenTitle: String?

    // The file
    private let tq = DispatchQueue(label: "sticky.chat.transcript")  // every ChatTranscript.update() runs here
    private var transcript: ChatTranscript?  // the file shown
    private var next: ChatTranscript?        // a copy's or /clear's new file, until it has rows
    private var wantFile: String?            // an id whose file hasn't shown up yet
    private var hasFile = false
    private var items: [ChatItem] = []
    private var counts: [String: Int] = [:]  // reply id → rows of it on file
    private var meta = ChatMeta()
    private var loading = false
    private var syncing = false
    private var syncAgain = false
    private var syncSeq = 0                  // syncs started, so "a sync has run since" can be told
    private var syncWork: DispatchWorkItem?
    private var syncAt = 0.0
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var ticks = 0
    private var live: LiveSession?           // another Claude has this chat open
    private var checkingLive = false
    private static var indexRefreshed = 0.0  // when a chat sticky last refreshed ChatIndex (for the app's titles)

    // The page
    private var pageReady = false
    private var allowLoad = true
    private var shown: [ChatItem]?           // what the page has; nil = it needs a reset
    private var start = 0                    // where `shown` starts in `items`
    private var limit = 250
    private var dirty: Set<Part> = []
    private var flushWork: DispatchWorkItem?
    private var lastFlush = 0.0
    private var wantFocus = false
    private var lastTitle = ""

    // Claude
    private var process: ClaudeProcess?
    private var gen = 0                      // events from an older process are ignored
    private var stopping = false
    private var procCwd: String?
    private var turn = false
    private var cliTurn = false              // claude says a turn runs (its init, or our message started), no result yet
    private var bgTasks = 0                  // background tasks our claude has running
    private var ourTail: String?             // the last item on file after our claude's last turn; it changed = another wrote
    private var tailAfter: Int?              // syncSeq when that turn ended: the next sync sets ourTail
    private var trustedFolder: String?       // a folder Claude Code (or you, in Sticky) trusts
    private var trustCard: PermCard?         // "Trust this folder?", before claude first runs in an untrusted one
    private var held: [(uuid: String, text: String, images: [(mime: String, base64: String)])] = []  // wait for that answer
    private var pending: [PendingMessage] = []
    private var ghost: [ClaudeProcess.StreamBlock] = []
    private var ghostEnd: (seq: Int, ids: Set<String>)?
    private var cards: [PermCard] = []
    private var mode: String
    private var model: String?               // what you picked; else the chat's last model
    private var cost: String?
    private var error: String?
    private var notice: String?
    private var idleWork: DispatchWorkItem?
    private var closed = false

    /// A turn is running, or a message waits for one.
    private var running: Bool { process != nil && (turn || pending.contains { $0.state == "queued" }) }

    init(session: String?, folder: String, title: String?, mode: String?, model: String?) {
        self.session = session.flatMap { $0.isEmpty ? nil : $0 }
        baseFolder = folder
        givenTitle = title.map { Self.oneLine($0, 120) }.flatMap { $0.isEmpty ? nil : $0 }
        self.mode = mode.flatMap { Self.safeModes.contains($0) ? $0 : nil } ?? "default"
        self.model = model.flatMap { $0.isEmpty ? nil : $0 }

        // Its own throwaway storage (no cookies, no keychain prompt) and no web extensions.
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let bridge = ChatBridge()
        cfg.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "sticky")
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        bridge.target = self
        webView.navigationDelegate = self
        webView.isInspectable = true  // right-click → Inspect Element, for debugging
        webView.loadHTMLString(ChatPage.html, baseURL: nil)

        if let s = self.session {
            if let p = ChatIndex.findFile(s) {
                use(ChatTranscript(path: p))
                loading = true
            } else {
                wantFile = s  // a new chat whose first message never reached a file
            }
            checkLive()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        sync()
    }

    /// Puts the cursor in the message box.
    func focus() {
        wantFocus = true
        render()
        syncSoon(0)
    }

    /// Stops claude, the file watcher and the timers, and lets go of the page.
    func shutDown() {
        guard !closed else { return }
        closed = true
        gen += 1
        process?.stop()
        process = nil
        watcher?.cancel()
        watcher = nil
        timer?.invalidate()
        timer = nil
        [syncWork, flushWork, idleWork].forEach { $0?.cancel() }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sticky", contentWorld: .page)
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    // MARK: Reading the file

    /// Shows this file from now on, and watches it.
    private func use(_ t: ChatTranscript) {
        if transcript != nil { shown = nil }  // another file: its image keys mean other images
        transcript = t
        hasFile = true
        watch(t.path)
    }

    /// Reads what the file gained on the background queue, then updates the page.
    private func sync() {
        syncWork?.cancel()
        syncWork = nil
        guard !closed else { return }
        lookForFile()
        guard let t = transcript else {
            if loading { loading = false; render(.status) }
            return
        }
        if syncing { syncAgain = true; return }
        syncing = true
        syncSeq += 1
        let seq = syncSeq, n = next
        tq.async { [weak self] in
            let a = t.update() ? ChatSnap(t) : nil
            let b = n.flatMap { $0.update() ? ChatSnap($0) : nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.synced(t, a, n, b, seq) }
            }
        }
    }

    private func synced(_ t: ChatTranscript, _ a: ChatSnap?, _ n: ChatTranscript?, _ b: ChatSnap?, _ seq: Int) {
        syncing = false
        guard !closed else { return }
        var snap = t === transcript ? a : nil
        if let n, n === next, let b, !b.items.isEmpty {
            // The new file (a copy, or after /clear) has rows: show it from now on.
            next = nil
            use(n)
            snap = b
        }
        if let s = snap {
            items = s.items
            counts = s.counts
            meta = s.meta
            render(.items, .ghost, .status)
        }
        if loading, t === transcript { loading = false; render(.status) }
        if let a = tailAfter, seq > a {
            ourTail = items.last?.id  // what the file ends with after our turn: anything else is another Claude's
            tailAfter = nil
        }
        settle(seq)
        if syncAgain { syncAgain = false; sync() }
    }

    /// Soon: 80 ms while our turn streams, else 250 ms. An earlier request wins.
    private func syncSoon(_ delay: Double? = nil) {
        let d = delay ?? (running ? 0.08 : 0.25)
        let at = ProcessInfo.processInfo.systemUptime + d
        if syncWork != nil, syncAt <= at { return }
        syncWork?.cancel()
        syncAt = at
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.sync() } }
        syncWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: w)
    }

    /// A new chat, a copy or /clear gave the chat an id whose file is still to come. The old items stay until it has rows.
    private func lookForFile() {
        guard let id = wantFile else { return }
        let guess = ChatIndex.projectsDir.appendingPathComponent(ChatIndex.encode(procCwd ?? folder))
            .appendingPathComponent(id + ".jsonl").path
        guard let p = FileManager.default.fileExists(atPath: guess) ? guess : ChatIndex.findFile(id) else { return }
        wantFile = nil
        let t = ChatTranscript(path: p)
        if transcript == nil { use(t) } else { next = t }
    }

    private func watch(_ path: String) {
        watcher?.cancel()
        watcher = nil
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fileChanged() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        watcher = s
    }

    private func fileChanged() {
        guard let w = watcher else { return }
        if !w.data.isDisjoint(with: [.delete, .rename]) {
            // Replaced or moved: watch whatever has the name in a moment.
            w.cancel()
            watcher = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.rewatch() }
            }
        }
        syncSoon()
    }

    private func rewatch() {
        guard !closed, watcher == nil, let t = transcript else { return }
        if FileManager.default.fileExists(atPath: t.path) {
            watch(t.path)
        } else if let p = ChatIndex.findFile(Self.stem(t.path)), p != t.path {
            use(ChatTranscript(path: p))  // the chat moved to another folder
        }
        syncSoon(0)
    }

    /// Every 1.5 s: catch what the watcher missed while it's on screen or a turn runs; every 3 s, who else has it open.
    private func tick() {
        guard !closed else { return }
        ticks += 1
        let visible = onScreen
        if visible || running {
            if watcher == nil { rewatch() }
            sync()
        }
        if visible, ticks % 2 == 0 { checkLive() }
        // A rename in the Claude app reaches ChatIndex on its next refresh: one every 2 minutes while a chat shows.
        let now = ProcessInfo.processInfo.systemUptime
        if visible, now - Self.indexRefreshed > 120 {
            Self.indexRefreshed = now
            ChatIndex.shared.refresh()
        }
        updateTitle()
    }

    private var onScreen: Bool {
        guard let w = webView.window else { return false }
        return w.isVisible && w.alphaValue > 0 && w.occlusionState.contains(.visible)
    }

    /// Whether another Claude (the app, a terminal) has this chat open right now, read off the main thread.
    private func checkLive() {
        guard let id = session, !checkingLive else { return }
        checkingLive = true
        let ours = ClaudeProcess.runningPids()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let l = ChatIndex.liveSessions(ignoring: ours)[id]
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.checkingLive = false
                    guard id == self.session, (l == nil) != (self.live == nil) || l?.busy != self.live?.busy else { return }
                    self.live = l
                    self.render(.status)
                }
            }
        }
    }

    /// After a sync: sent messages that are now on file go, and so do live blocks that are rows now.
    private func settle(_ seq: Int) {
        let fresh = items.suffix(400).filter { $0.kind == "user" }
        var used = Set<String>()
        let before = pending.count
        pending.removeAll { p in
            if let d = p.doneAt, seq > d { return true }
            guard let u = fresh.first(where: { !p.known.contains($0.id) && !used.contains($0.id)
                && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == p.text }) else { return false }
            used.insert(u.id)
            return true
        }
        if pending.count != before { render(.pending, .status) }
        if let e = ghostEnd, seq > e.seq {
            ghost.removeAll { e.ids.contains($0.messageId) }
            ghostEnd = nil
            render(.ghost, .status)
        }
    }

    // MARK: Sending to the page

    /// Marks parts of the page out of date. They go out together, at most every 50 ms.
    private func render(_ parts: Part...) {
        dirty.formUnion(parts)
        updateTitle()
        guard pageReady, flushWork == nil else { return }
        let wait = max(0, lastFlush + 0.05 - ProcessInfo.processInfo.systemUptime)
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        flushWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
    }

    private func flush() {
        flushWork?.cancel()
        flushWork = nil
        updateTitle()
        guard pageReady, !closed else { return }
        lastFlush = ProcessInfo.processInfo.systemUptime
        let d = dirty
        dirty = []
        if d.contains(.items) { flushItems() }
        if d.contains(.pending) { post(["op": "pending", "items": pending.map(\.js)]) }
        if d.contains(.ghost) { post(["op": "ghost", "blocks": ghostBlocks]) }
        if d.contains(.perms) { post(["op": "permissions", "requests": (trustCard.map { [$0] } ?? []).map(\.js) + cards.map(\.js)]) }
        if d.contains(.status) { post(["op": "status", "s": status]) }
        if wantFocus { wantFocus = false; post(["op": "focus"]) }
    }

    /// If the page's items are still the start of the chat's, only the changed and new ones go; else all again.
    private func flushItems() {
        guard let old = shown else { return resetItems() }
        guard let first = old.first else {
            if !items.isEmpty { resetItems() }
            return
        }
        let at: Int
        if start < items.count, items[start].id == first.id {
            at = start
        } else if let k = items.firstIndex(where: { $0.id == first.id }) {
            at = k
        } else {
            return resetItems()
        }
        let win = items[at...]
        guard win.count >= old.count, zip(old, win).allSatisfy({ $0.id == $1.id }) else { return resetItems() }
        var out: [[String: Any]] = []
        for (k, it) in win.enumerated() where k >= old.count || old[k] != it { out.append(it.js) }
        start = at
        shown = Array(win)
        guard !out.isEmpty else { return }
        post(["op": "upsert", "items": out])
        onActivity?()
    }

    private func resetItems() {
        let from = max(0, items.count - limit)
        let win = Array(items[from...])
        start = from
        shown = win
        post(["op": "reset", "items": win.map(\.js), "hasEarlier": from > 0])
        if !win.isEmpty { onActivity?() }
    }

    /// "Load earlier messages": 250 more at the top.
    private func loadEarlier() {
        if dirty.contains(.items) { dirty.remove(.items); flushItems() }
        guard let old = shown, let first = old.first, start > 0, start < items.count, items[start].id == first.id else {
            post(["op": "prepend", "items": [Any](), "hasEarlier": false])
            return
        }
        let from = max(0, start - 250)
        let older = Array(items[from..<start])
        shown = older + old
        start = from
        limit += 250
        post(["op": "prepend", "items": older.map(\.js), "hasEarlier": from > 0])
    }

    private func post(_ m: [String: Any]) {
        guard pageReady else { return }
        webView.callAsyncJavaScript("chat.receive(m)", arguments: ["m": m], in: nil, in: .page, completionHandler: nil)
    }

    private func updateTitle() {
        guard !loading, let f = onTitle else { return }
        let t = (running ? "● " : "") + title
        guard t != lastTitle else { return }
        lastTitle = t
        f(t)
    }

    /// The reply being written, minus the blocks that are rows in the file by now.
    private var ghostBlocks: [[String: Any]] {
        ghost.filter { (counts[$0.messageId] ?? 0) <= $0.index }.map { b in
            var d: [String: Any] = ["key": "\(b.messageId).\(b.index)", "kind": b.kind,
                                    "text": b.kind == "tool" ? "" : b.text]  // a tool's half-written input isn't shown
            if let n = b.toolName { d["name"] = n }
            return d
        }
    }

    private var status: [String: Any] {
        let f = folder
        var s: [String: Any] = [
            "title": title, "folder": f, "running": running,
            "busyElsewhere": live?.busy == true, "liveElsewhere": live != nil, "trustWait": trustCard != nil,
            "mode": mode, "modes": Self.modes,
            "models": Self.models.map { ["value": $0.value, "label": $0.label] },
            "loading": loading,
        ]
        if let b = meta.branch { s["branch"] = b }
        if process == nil, !Self.isFolder(f) { s["readOnly"] = "This chat's folder is gone" }
        if let e = error { s["error"] = e }
        if let n = notice { s["notice"] = n }
        if let m = model ?? meta.lastModel { s["model"] = m }
        if let c = cost { s["cost"] = c }
        if items.isEmpty { s["empty"] = hasFile ? "No messages yet" : "New chat in \((f as NSString).lastPathComponent)" }
        return s
    }

    // MARK: Messages from the page

    fileprivate func received(_ b: [String: Any], reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard !closed else { reply(nil, nil); return }
        switch b["type"] as? String {
        case "ready":
            // Also after the page reloads (its process crashed): everything goes again.
            pageReady = true
            shown = nil
            dirty = Set(Part.allCases)
            flush()
            reply(nil, nil)
        case "send":
            let images: [(mime: String, base64: String)] = (b["images"] as? [[String: Any]] ?? []).compactMap { i in
                guard let m = i["mime"] as? String, ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(m),
                      let d = i["data"] as? String, !d.isEmpty else { return nil }
                return (m, d)
            }
            if let e = send(Self.valid(b["text"] as? String ?? ""), images) {
                reply(["ok": false, "error": e], nil)
            } else {
                reply(["ok": true], nil)
            }
        case "stop":
            process?.interrupt()
            reply(nil, nil)
        case "answer":
            answer(b)
            reply(nil, nil)
        case "loadEarlier":
            loadEarlier()
            reply(nil, nil)
        case "setMode":
            if let v = b["value"] as? String { setMode(v) }
            reply(nil, nil)
        case "setModel":
            if let v = b["value"] as? String { setModel(v) }
            reply(nil, nil)
        case "openLink":
            if let s = b["url"] as? String, let u = URL(string: s),
               ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") { onOpenURL?(u) }
            reply(nil, nil)
        case "image":
            guard let key = b["key"] as? String, let t = transcript else { reply(nil, nil); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let u = t.image(key)  // reads only that row from the file; safe next to update()
                DispatchQueue.main.async { MainActor.assumeIsolated { reply(u, nil) } }
            }
        case "copy":
            if let t = b["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
            }
            reply(nil, nil)
        default:
            reply(nil, nil)
        }
    }

    /// Sends a message, starting claude first if it isn't running. Returns why it couldn't, or nil.
    private func send(_ text: String, _ images: [(mime: String, base64: String)]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return "There's nothing to send." }
        if let p = process, !stopping, let s = session {
            // Another Claude may have opened this chat since ours started, or written to it and gone. Ours must not
            // write on into the same file: start again (as a copy if the other one is still there).
            let other = ChatIndex.liveSessions(ignoring: ClaudeProcess.runningPids())[s] != nil
            if other, running {
                return "This chat is open in another Claude too. Wait for this reply, then send to continue in a copy."
            }
            let wrote = bgTasks == 0 && ourTail != nil && items.last?.id != ourTail
            if !running, other || wrote {
                stopping = true
                p.stop()
            }
        }
        if process == nil || stopping {
            // Claude Code skips its "Do you trust this folder?" question in this mode, so it's asked here first.
            if trustCard != nil || (Self.isFolder(folder) && !folderTrusted()) { return hold(text, trimmed, images) }
            if let e = startProcess(firstText: trimmed) { return e }
        }
        guard let p = process else { return "Claude isn't running." }
        dispatch(p, (Self.newId(), text, images), trimmed)
        return nil
    }

    /// Hands a message to claude; its bubble shows until the file has it.
    private func dispatch(_ p: ClaudeProcess, _ m: (uuid: String, text: String, images: [(mime: String, base64: String)]),
                          _ trimmed: String) {
        error = nil
        idleWork?.cancel()
        let state = running ? "queued" : "sending"
        if let k = pending.firstIndex(where: { $0.id == m.uuid }) {
            pending[k].state = state
        } else {
            pending.append(PendingMessage(
                id: m.uuid, text: trimmed, images: m.images.map { "data:\($0.mime);base64,\($0.base64)" },
                state: state, known: Set(items.lazy.filter { $0.kind == "user" }.map(\.id))))
        }
        turn = true
        p.send(m.text, images: m.images, uuid: m.uuid)
        render(.pending, .status)
    }

    /// Whether Claude Code trusts the chat's folder (or you said to, in Sticky).
    private func folderTrusted() -> Bool {
        let f = folder
        if trustedFolder == f { return true }
        guard ChatIndex.isTrusted(f) else { return false }
        trustedFolder = f
        return true
    }

    /// Keeps a message until "Trust this folder?" is answered.
    private func hold(_ text: String, _ trimmed: String, _ images: [(mime: String, base64: String)]) -> String? {
        let uuid = Self.newId()
        pending.append(PendingMessage(
            id: uuid, text: trimmed, images: images.map { "data:\($0.mime);base64,\($0.base64)" },
            state: "queued", known: Set(items.lazy.filter { $0.kind == "user" }.map(\.id))))
        held.append((uuid, text, images))
        if trustCard == nil {
            let name = (folder as NSString).abbreviatingWithTildeInPath
            trustCard = PermCard(id: Self.trustId, input: [:], js: [
                "id": Self.trustId, "tool": "trust", "trust": true,
                "title": "Trust " + Self.code(name) + "?",
                "reason": "Claude Code hasn't been told to trust this folder. When Claude starts here, the folder's own "
                    + "Claude settings, hooks and MCP servers run too, and they can run any command. Only trust a folder you know.",
            ])
        }
        render(.pending, .perms, .status)
        return nil
    }

    private static let trustId = "sticky-trust"

    /// "Trust this folder?" answered: start claude and send what waited, or give the messages back.
    private func trustAnswered(_ yes: Bool) {
        trustCard = nil
        let msgs = held
        held = []
        var started = false
        if yes {
            ChatIndex.trust(folder)
            trustedFolder = folder
            let first = msgs.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process != nil && !stopping {
                started = true
            } else if let e = startProcess(firstText: first) {
                error = e
            } else {
                started = true
            }
        }
        if started, let p = process {
            for m in msgs { if let k = pending.firstIndex(where: { $0.id == m.uuid }) { pending[k].state = "sending" } }
            for m in msgs where pending.contains(where: { $0.id == m.uuid }) {
                dispatch(p, m, m.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else {
            for m in msgs { if let k = pending.firstIndex(where: { $0.id == m.uuid }) { cancel(k) } }  // back in the box
        }
        render(.pending, .perms, .status)
    }

    /// Starts claude for this chat: continues it, continues a copy (another Claude has it open), or starts it new.
    private func startProcess(firstText: String) -> String? {
        let cwd = folder
        guard Self.isFolder(cwd) else {
            render(.status)
            return "This chat's folder is gone."
        }
        var o = ClaudeProcess.Options(cwd: cwd)
        var newId: String?
        var ownTitle: String?
        var forkNotice: String?
        let shownId = transcript.map { Self.stem($0.path) }
        if let s = session, s == shownId || ChatIndex.findFile(s) != nil {
            if ChatIndex.liveSessions(ignoring: ClaudeProcess.runningPids())[s] != nil {
                // Two claudes writing one chat would tangle it.
                let id = Self.newId()
                o.resume = s
                o.fork = true
                o.sessionId = id
                newId = id
                ownTitle = title
                forkNotice = "This chat is open in another Claude (the app or a terminal), so Sticky continued it as a copy."
            } else {
                o.resume = s
            }
        } else if let f = shownId {
            // The id's file never got written (a copy or /clear that stopped early): copy the chat shown again.
            let id = session ?? Self.newId()
            o.resume = f
            o.fork = true
            o.sessionId = id
            newId = id
            ownTitle = title
        } else {
            // A new chat, or one whose first message never reached a file.
            let id = session ?? Self.newId()
            o.sessionId = id
            newId = id
            ownTitle = firstText.isEmpty ? nil : Self.oneLine(firstText, 80)
        }
        o.mode = mode
        o.model = model ?? meta.lastModel
        o.effort = meta.lastEffort

        gen += 1
        let g = gen
        let p = ClaudeProcess(o) { [weak self] e in self?.handle(e, gen: g) }
        do {
            try p.start()
        } catch let e {
            error = e.localizedDescription
            render(.status)
            return e.localizedDescription
        }
        process = p
        stopping = false
        procCwd = cwd
        turn = false
        cliTurn = false
        bgTasks = 0
        ourTail = nil
        tailAfter = nil
        notice = forkNotice
        if let id = newId {
            ChatIndex.shared.markOwn(id, title: ownTitle, cwd: cwd)  // Sticky's chats are "sdk-cli": list them anyway
            setSession(id)
        }
        return nil
    }

    /// The chat has a new id: remember it, and switch to its file once that shows up.
    private func setSession(_ id: String) {
        let changed = id != session
        session = id
        if changed {
            onSession?(id)
            live = nil
        }
        if transcript.map({ Self.stem($0.path) }) != id {
            wantFile = id
            next = nil
            lookForFile()
        }
    }

    private func answer(_ b: [String: Any]) {
        if b["id"] as? String == Self.trustId, trustCard != nil {
            trustAnswered(b["behavior"] as? String == "allow")
            return
        }
        guard let id = b["id"] as? String, let k = cards.firstIndex(where: { $0.id == id }) else { return }
        let c = cards.remove(at: k)
        render(.perms, .status)
        guard let p = process else { return }
        if b["behavior"] as? String == "allow" {
            if let a = b["answers"] as? [String: Any] {
                var input = c.input
                input["answers"] = a.compactMapValues { ($0 as? String).map(Self.valid) }
                p.allow(id, updatedInput: input)
            } else {
                p.allow(id, always: b["always"] as? Bool == true)
            }
        } else {
            let m = (b["message"] as? String).map(Self.valid).flatMap { $0.isEmpty ? nil : $0 } ?? "The user denied this."
            p.deny(id, message: m)
        }
    }

    private func setMode(_ v: String) {
        guard Self.safeModes.contains(v) else { render(.status); return }
        mode = v
        process?.setMode(v)
        onSettings?(mode, model)
        render(.status)
    }

    private func setModel(_ v: String) {
        guard !v.isEmpty else { return }
        model = v
        process?.setModel(v)
        onSettings?(mode, model)
        render(.status)
    }

    // MARK: Events from claude

    private func handle(_ e: ClaudeProcess.Event, gen g: Int) {
        guard g == gen, !closed else { return }
        switch e {
        case .sessionId(let id):
            guard id != session else { return }
            ChatIndex.shared.markOwn(id, title: nil, cwd: procCwd)  // after /clear: a chat of its own
            setSession(id)
            syncSoon(0.08)
        case .ready(let models, let m):
            if !models.isEmpty { Self.models = models }
            if Self.safeModes.contains(m) { mode = m }
            render(.status)
        case .lifecycle(let uuid, let state):
            lifecycle(uuid, state)
        case .streaming(let blocks):
            // Blocks of an earlier reply stay until they're rows (or the turn ends), so nothing blinks out.
            let ids = Set(blocks.map(\.messageId))
            ghost = ghost.filter { !ids.contains($0.messageId) } + blocks
            render(.ghost)
        case .permission(let r):
            cards.removeAll { $0.id == r.id }
            cards.append(Self.card(r))
            idleWork?.cancel()
            render(.perms, .status)
        case .permissionCancelled(let id):
            cards.removeAll { $0.id == id }
            render(.perms, .status)
            scheduleIdle()
        case .turnStarted:
            // Also a turn claude starts by itself (a background task finished): busy, Stop works, no idle stop.
            cliTurn = true
            turn = true
            idleWork?.cancel()
            idleWork = nil
            render(.status)
        case .backgroundTasks(let n):
            bgTasks = n
            if n == 0 { scheduleIdle() }  // the 10 minutes start once the last one is done
        case .turnEnded(let r):
            turn = false
            cliTurn = false
            tailAfter = syncSeq
            ourTail = nil
            if let c = r.costUSD { cost = c < 0.01 ? "<$0.01" : String(format: "$%.2f", c) }
            if r.isError, !(r.reason ?? "").hasPrefix("aborted"),
               let m = r.errors.first(where: { !$0.hasPrefix("[ede_diagnostic]") }) { error = m }
            for k in pending.indices where pending[k].started && pending[k].doneAt == nil && pending[k].state != "cancelled" {
                pending[k].doneAt = syncSeq
            }
            ghostEnd = (syncSeq, Set(ghost.map(\.messageId)))
            syncSoon(0)
            scheduleIdle()
            render(.pending, .ghost, .status)
        case .modeChanged(let m):
            guard Self.safeModes.contains(m) else { return }
            if m != mode {
                mode = m
                onSettings?(mode, model)
            }
            render(.status)
        case .modelChanged(let m):
            model = m
            render(.status)
        case .wrote:
            lookForFile()
            syncSoon(0.08)
        case .exited(_, let err):
            process = nil
            stopping = false
            turn = false
            cliTurn = false
            bgTasks = 0
            ourTail = nil
            tailAfter = nil
            idleWork?.cancel()
            cards = []
            ghost = []
            ghostEnd = nil
            if let err { error = err }
            // Messages that never ran won't now. The next send starts claude again.
            for k in pending.indices where pending[k].doneAt == nil && pending[k].state != "cancelled" {
                if pending[k].started { pending[k].doneAt = syncSeq } else { cancel(k) }
            }
            syncSoon(0)
            render(.pending, .ghost, .perms, .status)
        }
    }

    private func lifecycle(_ uuid: String, _ state: String) {
        guard let k = pending.firstIndex(where: { $0.id == uuid }) else { return }
        switch state {
        case "started":
            pending[k].state = "sending"
            pending[k].started = true
            turn = true
            cliTurn = true
        case "completed":
            pending[k].doneAt = syncSeq  // gone after the next sync, which shows it from the file
            syncSoon(0)
        case "cancelled":
            if pending[k].started {
                pending[k].doneAt = syncSeq  // it ran before the stop, so it's on file
                syncSoon(0)
            } else {
                cancel(k)
                // Stopped before claude began a turn (it was still starting up): no result will come, so nothing runs.
                if !cliTurn, !pending.contains(where: { !$0.started && $0.doneAt == nil && $0.state != "cancelled" }) {
                    turn = false
                    scheduleIdle()
                }
            }
        default:
            break
        }
        render(.pending, .status)
    }

    /// "Not sent" for 3 s, then gone.
    private func cancel(_ k: Int) {
        pending[k].state = "cancelled"
        let id = pending[k].id
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending.removeAll { $0.id == id && $0.state == "cancelled" }
                self.render(.pending, .status)
            }
        }
    }

    /// 10 minutes after a turn ends with no cards, claude stops (not while it runs a background task: stopping would
    /// end it). The next message starts it again (with --resume).
    private func scheduleIdle() {
        idleWork?.cancel()
        idleWork = nil
        guard process != nil, !running, cards.isEmpty else { return }
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let p = self.process, !self.running, self.cards.isEmpty else { return }
                if self.bgTasks > 0 { self.scheduleIdle(); return }
                self.stopping = true
                p.stop()
            }
        }
        idleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: w)
    }

    // MARK: Permission cards

    private static func card(_ r: ClaudeProcess.PermissionRequest) -> PermCard {
        let i = r.input
        func s(_ k: String) -> String? { (i[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var js: [String: Any] = ["id": r.id, "tool": r.toolName]
        var title: String
        var detail: String?
        switch r.toolName {
        case "Bash":
            let cmd = s("command") ?? ""
            let first = cmd.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            var line = oneLine(first, 80)
            if first.count < cmd.trimmingCharacters(in: .whitespacesAndNewlines).count, !line.hasSuffix("…") { line += "…" }
            title = "Claude wants to run " + code(line)
            detail = cmd
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = s("file_path") ?? s("notebook_path") ?? ""
            let name = path.isEmpty ? "a file" : (path as NSString).abbreviatingWithTildeInPath  // where it is matters
            let verb = r.toolName == "Write" && !path.isEmpty && !FileManager.default.fileExists(atPath: path) ? "create" : "edit"
            title = "Claude wants to \(verb) \(name)"
            detail = diff(r.toolName, i) ?? (path.isEmpty ? nil : (path as NSString).abbreviatingWithTildeInPath)
        case "Read":
            title = "Claude wants to read " + (s("file_path").map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "a file")
        case "WebFetch":
            // The whole address goes in the details (a long query string is where data would leave), the site on top.
            let url = s("url")
            title = "Claude wants to open " + (url.map { URL(string: $0)?.host ?? oneLine($0, 80) } ?? "a web page")
            detail = [url, s("prompt")].compactMap { $0 }.joined(separator: "\n\n")
        case "WebSearch":
            title = "Claude wants to search the web for “\(oneLine(s("query") ?? "", 80))”"
        case "ExitPlanMode":
            title = "Start on this plan?"
            js["plan"] = s("plan") ?? ""
        case "AskUserQuestion":
            let qs = questions(i["questions"])
            title = qs.count > 1 ? "Claude has \(qs.count) questions" : "Claude has a question"
            if qs.isEmpty { detail = pretty(i) } else { js["question"] = qs }
        default:
            title = "Claude wants to use " + toolName(r.displayName)
            detail = i.isEmpty ? nil : pretty(i)
        }
        js["title"] = title
        if let d = detail, !d.isEmpty { js["detail"] = clip(d, 20_000) }
        var why: [String] = []
        if r.agentId != nil { why.append("Asked by a subagent") }
        if let x = r.reason, !x.isEmpty {
            why.append(x)
        } else if r.toolName == "Bash", let d = s("description") ?? r.description, d != s("command") {
            why.append(d)
        }
        if !why.isEmpty { js["reason"] = why.joined(separator: " · ") }
        if let a = r.alwaysLabel { js["always"] = a }
        return PermCard(id: r.id, input: i, js: js)
    }

    /// An edit's change as "-" / "+" lines, for the card.
    private static func diff(_ tool: String, _ i: [String: Any]) -> String? {
        func lines(_ s: String, _ mark: String) -> [String] {
            s.isEmpty ? [] : s.components(separatedBy: "\n").map { mark + $0 }
        }
        var out: [String] = []
        switch tool {
        case "Edit":
            if let o = i["old_string"] as? String, let n = i["new_string"] as? String { out = lines(o, "-") + lines(n, "+") }
        case "MultiEdit":
            for e in i["edits"] as? [[String: Any]] ?? [] {
                guard let o = e["old_string"] as? String, let n = e["new_string"] as? String else { continue }
                if !out.isEmpty { out.append("@@") }
                out += lines(o, "-") + lines(n, "+")
            }
        case "Write":
            if let c = i["content"] as? String { out = lines(c, "+") }
        case "NotebookEdit":
            if let c = i["new_source"] as? String { out = lines(c, "+") }
        default:
            break
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    /// AskUserQuestion's questions, in the page's shape.
    private static func questions(_ raw: Any?) -> [[String: Any]] {
        (raw as? [[String: Any]] ?? []).compactMap { q in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            var o: [String: Any] = ["question": text, "multiSelect": q["multiSelect"] as? Bool ?? false]
            if let h = q["header"] as? String, !h.isEmpty { o["header"] = h }
            o["options"] = (q["options"] as? [[String: Any]] ?? []).compactMap { op -> [String: Any]? in
                guard let l = op["label"] as? String, !l.isEmpty else { return nil }
                var x: [String: Any] = ["label": l]
                if let d = op["description"] as? String, !d.isEmpty { x["description"] = d }
                return x
            }
            return o
        }
    }

    // MARK: Helpers

    /// "mcp__notion__search" → "notion: search".
    private static func toolName(_ n: String) -> String {
        guard n.hasPrefix("mcp__") else { return n }
        let parts = n.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return n }
        return parts[0].replacingOccurrences(of: "_", with: " ") + ": "
            + parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " ")
    }

    /// `text` as a code span in a card title (a backtick inside would end it early).
    private static func code(_ s: String) -> String {
        "`" + s.replacingOccurrences(of: "`", with: "'") + "`"
    }

    private static func pretty(_ o: [String: Any]) -> String? { ChatTranscript.inputText(o) }

    /// Text from the page with broken UTF-16 (half of an emoji's pair) turned into U+FFFD, so it can go out as JSON.
    private static func valid(_ s: String) -> String { String(decoding: Array(s.utf8), as: UTF8.self) }

    private static func clip(_ s: String, _ max: Int) -> String {
        guard s.utf16.count > max else { return s }
        let ns = s as NSString
        let at = ns.rangeOfComposedCharacterSequence(at: max).location
        return ns.substring(to: at) + "\n… \(ns.length - at) more characters"
    }

    /// One line, runs of spaces and newlines as one space, at most `max` characters (cut ones end in "…").
    private static func oneLine(_ s: String, _ max: Int) -> String {
        let t = s.prefix(max * 8).split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return t.count > max ? String(t.prefix(max - 1)) + "…" : t
    }

    private static func stem(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private static func isFolder(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }

    private static func newId() -> String { UUID().uuidString.lowercased() }

    // MARK: WKNavigationDelegate

    /// Only our own page loads (and reloads, with ⌘R). A link the page didn't catch opens outside it.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let u = navigationAction.request.url
        let ours = navigationAction.targetFrame?.isMainFrame != false && (u == nil || u?.scheme == "about")
        if allowLoad, ours {
            allowLoad = false
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if ours, navigationAction.navigationType == .reload {
            reloadPage()  // a plain reload would come back blank: the page was loaded from a string
        } else if let u, ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            onOpenURL?(u)
        }
    }

    /// The page's process crashed: load it again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reloadPage()
    }

    /// Loads the page again. It says "ready", and gets everything.
    private func reloadPage() {
        guard !closed else { return }
        pageReady = false
        shown = nil
        allowLoad = true
        flushWork?.cancel()
        flushWork = nil
        webView.loadHTMLString(ChatPage.html, baseURL: nil)
    }
}

// MARK: - Small types

/// Passes the page's messages on without keeping the chat alive (the content controller holds its handlers).
@MainActor private final class ChatBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: ChatView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let t = target, let body = message.body as? [String: Any] else { replyHandler(nil, nil); return }
        t.received(body, reply: replyHandler)
    }
}

/// What the file says about the chat, besides its items.
private struct ChatMeta {
    var cwd: String?
    var title: String?
    var firstPrompt: String?
    var lastModel: String?
    var lastEffort: String?
    var branch: String?
}

/// A transcript's state, copied on its queue for the main thread.
private struct ChatSnap {
    var items: [ChatItem]
    var counts: [String: Int]
    var meta: ChatMeta

    init(_ t: ChatTranscript) {
        items = t.items
        counts = t.blockCounts
        meta = ChatMeta(cwd: t.cwd, title: t.title, firstPrompt: t.firstPrompt, lastModel: t.lastModel,
                        lastEffort: t.lastEffort, branch: t.gitBranch)
    }
}

/// A message you sent that isn't on file yet.
private struct PendingMessage {
    var id: String             // the uuid claude reports its lifecycle under
    var text: String           // trimmed, to spot it in the file
    var images: [String]       // data: URLs
    var state: String          // sending | queued | cancelled
    var known: Set<String>     // user items already there when it was sent
    var started = false
    var doneAt: Int?           // claude is done with it: gone once a sync after this one has run

    var js: [String: Any] { ["id": id, "text": text, "images": images, "state": state] }
}

/// A permission card: the request's input (an answer to a question sends it back) and the page's Perm.
private struct PermCard {
    var id: String
    var input: [String: Any]
    var js: [String: Any]
}
