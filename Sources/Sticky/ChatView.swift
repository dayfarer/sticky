// The chat inside a chat sticky: the page, the chat's file, and (only after you send) a way to send.
//
// The page (ChatPage) only draws. This keeps it in step with the chat's .jsonl, read on a background queue as
// it grows, plus what isn't on file yet: messages you just sent, the reply being written, and permission cards.
// Each message goes one of three ways, decided when you send it:
// 1. The Claude app (or a terminal claude) has the chat open with Sticky's mod (a live lease, Sync with Claude App
//    on): it goes through the bridge folder and runs there, as your own turn in the chat the app shows.
// 2. Another Claude has it open without the mod: nothing is written next to it. A banner offers Open in Claude and
//    Send as a copy.
// 3. Nothing else has it open: Sticky's own claude runs the turn, and quits a few seconds after it (so the file
//    says where the chat ends, for the next Claude that opens it). Restoring ten chat stickies starts no claude.
// With sync on, a new chat's first message goes to the Claude app's new-chat page, and the sticky follows the chat
// the app starts. When an app chat goes on under another id (a rewind or /clear there), the sticky follows it if a
// Claude has that open, and otherwise asks before it writes into the older part.
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
    /// Our claude runs a turn, a permission card is waiting, or it runs a background task (a dev server, say).
    /// (A turn the Claude app runs goes on without this sticky.)
    var isBusy: Bool { ownRunning || !cards.isEmpty || (process != nil && bgTasks > 0) }

    var onTitle: ((String) -> Void)?       // the sticky's title should change ("● " in front while running)
    var onSession: ((String) -> Void)?     // the chat's id changed (a new chat got its id, a copy, /clear)
    var onSettings: ((_ mode: String?, _ model: String?) -> Void)?  // you changed the mode or model
    var onActivity: (() -> Void)?          // new content (refresh the switcher picture soon)
    var onOpenURL: ((URL) -> Void)?
    var onFront: (() -> Void)?             // this new chat moved to the Claude app, which came forward: back on top
    var onTurnOnSync: (() -> Void)?        // the banner's "Turn on Sync with Claude App"

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
    private var startNotice: String?         // shown once a new claude starts
    private var grantRules: [String] = []    // "Always allow … in this chat" rules: every new claude of this chat gets them
    private var grantDirs: [String] = []     // and the folders granted that way
    private var idleWork: DispatchWorkItem?
    private var closed = false
    private var restart: [Outgoing] = []     // sent while our claude was still quitting: they go once it's gone
    private var restartCopy = false
    private var heldCopy = false             // what waits on "Trust this folder?" goes as a copy

    // The Claude app (Sync with Claude App)
    private var lease: BridgeLease?          // the Claude app (or a terminal claude) has it open, with Sticky's mod
    private var rawLease: BridgeLease?       // the same whether sync is on or not (a message the mod took may still run)
    private var leaseSeq = 0                 // a read that started before a newer one is dropped
    private var checkingLease = false
    private var sends: [String: BridgeSend] = [:]  // handed to the mod, not answered yet
    private var ackTimer: Timer?
    private var appTurnSince: Double?        // when the app's turn was first seen running (uptime)
    private var itemsAt = 0.0                // when the file last gained an item (uptime)
    private var appQuiet = false             // the app's turn has run 20 s with nothing new on file
    private var errorActions: [String] = []  // buttons beside `error`
    // A new chat Sticky starts moves to the Claude app once our claude has quit after a reply (claude --desktop).
    private var handoff: String?             // this chat moves then
    private var handingOff = false           // claude --desktop --resume runs
    private var movedAt: Double?             // uptime when it moved: sends wait for the app's lease until moveWait
    private var syncObserver: NSObjectProtocol?
    // The Claude app chat went on under another id (a rewind or /clear there)
    private var appCurrent: String?          // an id seen as the app chat's current part (only that one is followed)
    private var movedTo: String?             // its newer part, when nothing has that open (a banner asks)
    private var stayHere: String?            // "Send here anyway" was picked for this id
    private var checkingMove = false
    private var moveStat: AppPart?           // the app's session file as last read

    private typealias Outgoing = (uuid: String, text: String, images: [(mime: String, base64: String)])
    private static let idleExit = 3.0        // our claude quits this long after its turn
    private static let ackWait = 10.0        // the Claude app takes a message within this, or it comes back
    private static let quietWait = 20.0      // an app turn with nothing new on file this long: maybe a permission prompt
    private static let moveWait = 15.0       // a chat that moved: the Claude app opens it (and its mod) within this
    private static let lostWait = 10.0       // a message the mod took, with the chat idle this long and no answer: lost

    /// Our claude runs a turn, or a message waits for one.
    private var ownRunning: Bool { process != nil && (turn || pending.contains { $0.state == "queued" && !$0.app }) }
    /// The Claude app runs a turn in this chat.
    private var appBusy: Bool { lease?.busy == true }
    /// Either: the busy dot, Stop, "Working…".
    private var running: Bool { ownRunning || appBusy }
    /// Moving this chat to the Claude app, or waiting for the app to open it after the move.
    private var moving: Bool {
        handingOff || ((movedAt.map { ProcessInfo.processInfo.systemUptime - $0 < Self.moveWait } ?? false) && lease == nil)
    }

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
            checkLease()
            if ChatIndex.shared.isAppCurrent(s) { appCurrent = s }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        syncObserver = NotificationCenter.default.addObserver(forName: .stickyClaudeSync, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.syncTurned() }
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
        ackTimer?.invalidate()
        ackTimer = nil
        if let o = syncObserver { NotificationCenter.default.removeObserver(o) }
        syncObserver = nil
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
            if s.items.count != items.count || s.items.last?.id != items.last?.id {
                itemsAt = ProcessInfo.processInfo.systemUptime
                if appQuiet { appQuiet = false; render(.status) }
            }
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

    /// Every 1.5 s: catch what the watcher missed while it's on screen or a turn runs, and whether the mod has it open;
    /// every 3 s, who else has it open.
    private func tick() {
        guard !closed else { return }
        ticks += 1
        let visible = onScreen
        if visible || running || !sends.isEmpty {
            if watcher == nil { rewatch() }
            sync()
        }
        checkLease()
        // A chat that moved to the Claude app: the app has it open now, or it took too long. Either way, done.
        if let m = movedAt, lease != nil || ProcessInfo.processInfo.systemUptime - m >= Self.moveWait {
            movedAt = nil
            render(.status)
        }
        if visible, ticks % 2 == 0 { checkLive() }
        if visible, ticks % 3 == 0 { checkMoved() }
        // A turn in the Claude app with nothing new on file for a while may be waiting on a permission prompt there.
        let quiet = appTurnSince.map { ProcessInfo.processInfo.systemUptime - max($0, itemsAt) >= Self.quietWait } ?? false
        if quiet != appQuiet {
            appQuiet = quiet
            render(.status)
        }
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
                    guard id == self.session else { return }
                    self.setLive(l)
                }
            }
        }
    }

    private func setLive(_ l: LiveSession?) {
        guard (l == nil) != (live == nil) || l?.busy != live?.busy || l?.entrypoint != live?.entrypoint else { return }
        live = l
        render(.status)
    }

    /// Whether the mod has this chat open (its lease), read off the main thread.
    private func checkLease() {
        guard let id = session, !checkingLease else { return }
        checkingLease = true
        leaseSeq += 1
        let seq = leaseSeq
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let l = ClaudeBridge.lease(id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.checkingLease = false
                    guard id == self.session, seq == self.leaseSeq else { return }
                    self.setLease(l)
                }
            }
        }
    }

    /// A lease counts with sync on, for the Claude app's chats and terminal ones.
    private func setLease(_ raw: BridgeLease?) {
        rawLease = raw.flatMap { $0.isChatHost ? $0 : nil }
        let l = rawLease.flatMap { ClaudeSync.isOn ? $0 : nil }
        let was = lease
        lease = l
        if l?.busy == true {
            if appTurnSince == nil { appTurnSince = ProcessInfo.processInfo.systemUptime }
        } else {
            appTurnSince = nil
        }
        guard (l == nil) != (was == nil) || l?.state != was?.state || l?.entrypoint != was?.entrypoint
            || l?.canInterrupt != was?.canInterrupt else { return }
        if was?.busy == true, l?.busy != true { syncSoon(0) }  // its turn ended: the last rows, now
        // Messages that wait for the app's turn to end show as queued.
        for k in pending.indices where pending[k].app && !pending[k].started && sends[pending[k].id] != nil {
            pending[k].state = l?.busy == true ? "queued" : "sending"
        }
        render(.pending, .status)
    }

    /// Sync with Claude App was turned on or off: leases count, or stop counting.
    private func syncTurned() {
        setLease(rawLease)
        checkLease()
        render(.status)
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
            "busyElsewhere": lease == nil && live?.busy == true, "liveElsewhere": false, "trustWait": trustCard != nil,
            "mode": mode, "modes": Self.modes,
            "models": Self.models.map { ["value": $0.value, "label": $0.label] },
            "loading": loading,
        ]
        if let b = meta.branch { s["branch"] = b }
        if process == nil, lease == nil, !Self.isFolder(f) { s["readOnly"] = "This chat's folder is gone" }
        if let e = error {
            s["error"] = e
            if !errorActions.isEmpty { s["errorActions"] = errorActions.compactMap(Self.action) }
        }
        if let n = notice { s["notice"] = n }
        if let m = (lease != nil ? meta.lastModel : nil) ?? model ?? meta.lastModel { s["model"] = m }
        if let c = cost { s["cost"] = c }
        if items.isEmpty { s["empty"] = hasFile ? "No messages yet" : "New chat in \((f as NSString).lastPathComponent)" }
        if let l = lease {
            // Route 1: the chat runs in the Claude app (or a terminal); its mode, model and permission prompts are there.
            let app = l.entrypoint == "claude-desktop"
            s["locked"] = app ? "Set in the Claude app" : "Set in the terminal where this chat is open"
            if !l.canInterrupt { s["stopOff"] = app ? "Stop this reply in the Claude app" : "Stop this reply in its terminal" }
            if appQuiet {
                s["banner"] = ["icon": "info", "actions": app ? [Self.action("openInClaude")].compactMap { $0 } : [],
                               "text": app ? "Nothing new for 20 seconds. If Claude asked for permission, answer it in the Claude app."
                                           : "Nothing new for 20 seconds. If Claude asked for permission, answer it in its terminal."]
            }
        } else if let lv = live {
            s["banner"] = heldBanner(lv)
        } else if movedTo != nil {
            s["banner"] = ["icon": "app", "text": "This chat went on in the Claude app, after a rewind or /clear there",
                           "sub": "Sending here adds to the part before that, which the app no longer shows.",
                           "actions": ["openInClaude", "sendAnyway"].compactMap(Self.action)]
        }
        if moving { s["banner"] = ["icon": "spin", "text": "Moving this chat to the Claude app…"] }
        return s
    }

    /// Route 2: another Claude has the chat open, without Sticky's mod. Nothing is sent there; these are the ways on.
    private func heldBanner(_ lv: LiveSession) -> [String: Any] {
        let app = lv.entrypoint == "claude-desktop"
        var text = app ? "The Claude app has this chat open" : "Another Claude (a terminal, say) has this chat open"
        if lv.busy { text += " and is working on it" }
        var acts = app ? ["openInClaude", "sendCopy"] : ["sendCopy"]
        var b: [String: Any] = ["icon": lv.busy ? "spin" : "app", "text": text]
        if app || lv.entrypoint == "cli" {
            if !ClaudeSync.isOn {
                if ClaudeApp.isInstalled { acts.append("turnOnSync") }
            } else {
                // Its claude started before the mod was installed: only a new process loads it (sending from the app
                // doesn't restart it).
                b["sub"] = app
                    ? "It was open before sync was on, so it doesn't have Sticky's mod yet. Quitting and reopening the Claude app should load it."
                    : "That claude started before sync was on, so it doesn't have Sticky's mod. Quit it and resume the chat there to sync."
            }
        }
        b["actions"] = acts.compactMap(Self.action)
        return b
    }

    /// A banner button. The page runs sendCopy, sendHere, sendAnyway and restartSend/restartCopy itself (they need the
    /// composer); the rest come back here.
    private static func action(_ id: String) -> [String: Any]? {
        switch id {
        case "openInClaude": return ["id": id, "label": "Open in Claude"]
        case "sendCopy": return ["id": id, "label": "Send as a copy"]
        case "sendAnyway": return ["id": id, "label": "Send here anyway"]
        case "restartSend", "restartCopy": return ["id": id, "label": "Restart and send", "pri": true]
        case "dismissError": return ["id": id, "label": "Cancel"]
        case "turnOnSync": return ["id": id, "label": "Turn on Sync with Claude App"]
        default: return nil
        }
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
            let copy = b["copy"] as? Bool == true, here = b["here"] as? Bool == true, again = b["restart"] as? Bool == true
            if let e = send(Self.valid(b["text"] as? String ?? ""), images, copy: copy, here: here, restart: again) {
                // "": a banner says why already, so the page only puts the message back.
                reply(e.isEmpty ? ["ok": false, "quiet": true] : ["ok": false, "error": e], nil)
            } else {
                reply(["ok": true], nil)
            }
        case "stop":
            stopReply()
            reply(nil, nil)
        case "action":
            act(b["id"] as? String ?? "")
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

    /// Sends a message the way that fits right now (see the top of this file). Returns why it couldn't, or nil;
    /// "" when a banner says why already. `copy`: the banner's Send as a copy. `here`: not after the app chat's
    /// newer part (Send here anyway). `restart`: Restart and send
    /// (our claude may be stopped although it runs background tasks).
    private func send(_ text: String, _ images: [(mime: String, base64: String)], copy wantCopy: Bool = false,
                      here: Bool = false, restart again: Bool = false, followed: Bool = false) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return "There's nothing to send." }
        if handingOff {
            // "Moving this chat to the Claude app…": in a moment it goes there.
            post(["op": "nudge"])
            return ""
        }
        let copy = wantCopy && session != nil
        if let s = session, !copy {
            // 1. Open in the Claude app (or a terminal claude) with Sticky's mod: it runs there.
            leaseSeq += 1  // a read already on its way is older than this one
            setLease(ClaudeBridge.lease(s))
            if let l = lease { return sendToApp(text, trimmed, images, s, l) }
            // It just moved to the Claude app, which opens it in a moment: wait for that ("Moving this chat…").
            if moving {
                post(["op": "nudge"])
                render(.status)
                return ""
            }
            // 2. Open in another Claude without the mod: nothing is written next to it. The banner says what you can do.
            let other = ChatIndex.liveSessions(ignoring: ClaudeProcess.runningPids())[s]
            setLive(other)
            if other != nil {
                error = nil  // an older error would hide the banner and its buttons
                errorActions = []
                post(["op": "nudge"])
                render(.status)
                return ""
            }
            // The Claude app chat went on under another id (a rewind or /clear there): follow it, or ask.
            if here {
                stayHere = s
                movedTo = nil
            } else if !followed, stayHere != s, let c = movedNow(s) {
                if Self.isOpen(c) {
                    follow(c)
                    return send(text, images, restart: again, followed: true)
                }
                movedTo = c
                error = nil
                errorActions = []
                post(["op": "nudge"])
                render(.status)
                return ""
            }
        }
        if copy, ownRunning { return "Wait for this reply to end, then send it as a copy." }
        // 3. Nothing else has it open: Sticky's own claude.
        if let p = process, !stopping {
            // Another Claude may have written to it and gone since our turn, or this goes as a copy: start again.
            let wrote = ourTail != nil && items.last?.id != ourTail
            if !ownRunning, wrote || copy {
                if bgTasks > 0, !again {
                    // Stopping our claude ends its background tasks (a dev server, say): ask first.
                    let n = bgTasks
                    error = (wrote ? "Another Claude added to this chat since Sticky's last reply. " : "")
                        + "Sending restarts Sticky's claude, which ends its \(n) background task\(n == 1 ? "" : "s")."
                    errorActions = [copy ? "restartCopy" : "restartSend", "dismissError"]
                    post(["op": "nudge"])
                    render(.status)
                    return ""
                }
                stopping = true
                p.stop()
            }
        }
        // Our claude is still quitting. Until it's gone the file may not say where the chat ends: wait for it.
        if process != nil, stopping { return waitForExit((Self.newId(), text, images), trimmed, copy: copy) }
        if process == nil {
            // Claude Code skips its "Do you trust this folder?" question in this mode, so it's asked here first.
            if trustCard != nil || (Self.isFolder(folder) && !folderTrusted()) { return hold(text, trimmed, images, copy: copy) }
            if let e = startProcess(firstText: trimmed, copy: copy) { return e }
        }
        guard let p = process else { return "Claude isn't running." }
        dispatch(p, (Self.newId(), text, images), trimmed)
        return nil
    }

    /// Keeps a message until our quitting claude is gone; then a new one starts and takes it.
    private func waitForExit(_ m: Outgoing, _ trimmed: String, copy: Bool) -> String? {
        pending.append(PendingMessage(
            id: m.uuid, text: trimmed, images: m.images.map { "data:\($0.mime);base64,\($0.base64)" },
            state: "queued", known: Set(items.lazy.filter { $0.kind == "user" }.map(\.id))))
        restart.append(m)
        if copy { restartCopy = true }
        error = nil
        render(.pending, .status)
        return nil
    }

    /// Our claude is gone: start it again for what was sent meanwhile.
    private func restartAfterExit() {
        let msgs = restart, copy = restartCopy
        restart = []
        restartCopy = false
        let first = msgs.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let e = startProcess(firstText: first, copy: copy) {
            if !e.isEmpty { error = e }
            for m in msgs { if let k = pending.firstIndex(where: { $0.id == m.uuid }) { cancel(k) } }  // back in the box
        } else if let p = process {
            for m in msgs where pending.contains(where: { $0.id == m.uuid }) {
                dispatch(p, m, m.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        render(.pending, .status)
    }

    /// Hands a message to claude; its bubble shows until the file has it.
    private func dispatch(_ p: ClaudeProcess, _ m: Outgoing, _ trimmed: String) {
        error = nil
        errorActions = []
        idleWork?.cancel()
        let state = ownRunning ? "queued" : "sending"
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
    private func hold(_ text: String, _ trimmed: String, _ images: [(mime: String, base64: String)], copy: Bool) -> String? {
        let uuid = Self.newId()
        pending.append(PendingMessage(
            id: uuid, text: trimmed, images: images.map { "data:\($0.mime);base64,\($0.base64)" },
            state: "queued", known: Set(items.lazy.filter { $0.kind == "user" }.map(\.id))))
        held.append((uuid, text, images))
        if copy { heldCopy = true }
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
        let msgs = held, copy = heldCopy
        held = []
        heldCopy = false
        var started = false
        if yes {
            ChatIndex.trust(folder)
            trustedFolder = folder
            let first = msgs.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process != nil, stopping {
                // Our claude is still quitting: they go once it's gone.
                restart += msgs
                if copy { restartCopy = true }
                render(.pending, .perms, .status)
                return
            }
            if process != nil {
                started = true
            } else if let e = startProcess(firstText: first, copy: copy) {
                if !e.isEmpty { error = e }
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
            startNotice = nil
        }
        render(.pending, .perms, .status)
    }

    /// Starts claude for this chat: continues it, continues a copy (`copy`: Send as a copy), or starts it new.
    /// Returns why not, or nil; "" when another Claude has opened it since (the banner says so).
    private func startProcess(firstText: String, copy: Bool = false) -> String? {
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
            if copy {
                // Send as a copy: the other Claude keeps the chat, and this sticky goes on in a copy of it.
                let id = Self.newId()
                o.resume = s
                o.fork = true
                o.sessionId = id
                newId = id
                ownTitle = title
                forkNotice = "Sent as a copy. The other Claude keeps the original chat; this sticky shows the copy now."
            } else if let other = ChatIndex.liveSessions(ignoring: ClaudeProcess.runningPids())[s] {
                // Opened in another Claude since: two claudes writing one chat would tangle it.
                setLive(other)
                return ""
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
            // A new chat, or one whose first message never reached a file. With sync on it moves to the Claude app
            // once our claude has quit after this reply, so it's in the app's list too.
            let id = session ?? Self.newId()
            o.sessionId = id
            newId = id
            ownTitle = firstText.isEmpty ? nil : Self.oneLine(firstText, 80)
            if ClaudeSync.isOn, ClaudeApp.isInstalled { handoff = id }
        }
        o.mode = mode
        o.model = model ?? meta.lastModel
        o.effort = meta.lastEffort
        o.allowedTools = grantRules  // "Always allow … in this chat" outlives each claude (it quits after every reply)
        o.addDirs = grantDirs

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
        notice = forkNotice ?? startNotice
        startNotice = nil
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
            lease = nil
            rawLease = nil
            appTurnSince = nil
            movedTo = nil
            moveStat = nil
            if ChatIndex.shared.isAppCurrent(id) { appCurrent = id }
            checkLease()
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
        // An app chat's is set there, and so is that of a new chat that starts on the app's new-chat page.
        guard Self.safeModes.contains(v), lease == nil else { render(.status); return }
        mode = v
        process?.setMode(v)
        onSettings?(mode, model)
        render(.status)
    }

    private func setModel(_ v: String) {
        guard !v.isEmpty, lease == nil else { render(.status); return }
        model = v
        process?.setModel(v)
        onSettings?(mode, model)
        render(.status)
    }

    // MARK: The Claude app

    /// Route 1: leaves the message for the mod in the chat's outbox. Its bubble shows until the file has it (or
    /// the mod says no, or nothing takes it in 10 s: then it comes back to the composer).
    private func sendToApp(_ text: String, _ trimmed: String, _ images: [(mime: String, base64: String)], _ s: String,
                           _ l: BridgeLease) -> String? {
        guard images.isEmpty else {
            return "Images can't go to the Claude app from Sticky. Send the text here, and add the images in the Claude app."
        }
        if ownRunning { return "Wait for this reply to end, then send." }  // ours still runs a turn in this chat
        let id = Self.newId()
        do {
            try ClaudeBridge.post(session: s, id: id, kind: "prompt", text: text)
        } catch let e {
            return e.localizedDescription
        }
        if let p = process, !stopping {  // idle (the app has the chat now): it must not write on
            if bgTasks > 0 {
                notice = "Sticky's claude stopped so the Claude app's chat could take your message. That ended its "
                    + "\(bgTasks) background task\(bgTasks == 1 ? "" : "s")."
            }
            stopping = true
            p.stop()
        }
        error = nil
        errorActions = []
        pending.append(PendingMessage(
            id: id, text: trimmed, images: [], state: l.busy ? "queued" : "sending",
            known: Set(items.lazy.filter { $0.kind == "user" }.map(\.id)), app: true))
        sends[id] = BridgeSend(id: id, session: s, kind: "prompt", at: ProcessInfo.processInfo.systemUptime)
        watchAcks()
        render(.pending, .status)
        return nil
    }

    private func watchAcks() {
        guard ackTimer == nil, !sends.isEmpty else { return }
        ackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAcks() }
        }
    }

    /// Every 0.25 s while messages are out: their acks, their claims, and the ones nothing took.
    private func checkAcks() {
        guard !closed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A message the mod took may still run with sync off, or while its lease is late: only a chat no process has
        // open any more counts as gone (the registry, read off the main thread).
        if rawLease == nil, !sends.isEmpty { checkLive() }
        for id in Array(sends.keys) {
            guard var x = sends[id] else { continue }
            if let a = ClaudeBridge.ack(id) {
                ClaudeBridge.finish(session: x.session, id: id)
                sends[id] = nil
                acked(x, a)
                continue
            }
            if !x.claimed, ClaudeBridge.isClaimed(session: x.session, id: id) { x.claimed = true }
            if rawLease == nil, live == nil { x.goneAt = x.goneAt ?? now } else { x.goneAt = nil }
            var lost = false
            if x.claimed, let l = rawLease {
                // Taken, and then no answer: the mod's load may have been replaced before it sent it (a reload of the
                // Claude app's plugins drops what it was doing). Lost once the chat is idle and stays so, or another
                // load holds the chat, for a while.
                if x.claimers.isEmpty { x.claimers = Set(ClaudeBridge.claimers(session: x.session, id: id)) }
                let idle = !l.busy
                x.idleSince = idle ? (x.idleSince ?? now) : nil
                let other = idle && !x.claimers.isEmpty && !x.claimers.contains(l.loadId)
                x.otherSince = other ? (x.otherSince ?? now) : nil
                lost = (x.otherSince.map { now - $0 >= 5 } ?? false) || (x.idleSince.map { now - $0 >= Self.lostWait } ?? false)
            } else {
                x.idleSince = nil
                x.otherSince = nil
            }
            sends[id] = x
            if lost {
                ClaudeBridge.finish(session: x.session, id: id)  // its file gone: no load sends it later
                sends[id] = nil
                if x.kind == "prompt" {
                    failed(x, "The Claude app reloaded before sending this. Check the chat before resending.")
                } else {
                    checkLease()
                }
                continue
            }
            guard now - x.at >= Self.ackWait else { continue }
            if !x.claimed {
                // Nothing took it in 10 s: take it back (unless the mod claims it this very moment).
                ClaudeBridge.withdraw(session: x.session, id: id)
                if ClaudeBridge.isClaimed(session: x.session, id: id) {
                    // Claimed just now: with its file gone the mod won't run it, and its ack says so.
                    sends[id]?.claimed = true
                    sends[id]?.withdrawn = "timeout"
                    continue
                }
                ClaudeBridge.finish(session: x.session, id: id)
                sends[id] = nil
                failed(x, x.kind == "prompt" ? "The Claude app didn't take it." : "The Claude app didn't stop the reply.")
            } else if let g = x.goneAt, now - g >= 5 {
                // Taken, but the chat closed there before it said it ran it (a message it ran is on file by now).
                ClaudeBridge.finish(session: x.session, id: id)
                sends[id] = nil
                failed(x, "The Claude app closed this chat before it sent your message.")
            }
        }
        if sends.isEmpty {
            ackTimer?.invalidate()
            ackTimer = nil
        }
    }

    private func acked(_ x: BridgeSend, _ a: BridgeAck) {
        guard a.ok else {
            if x.withdrawn == "stop", x.kind == "prompt" {
                // Stop took it back: it comes back to the composer, like the ones the mod hadn't claimed.
                if let k = pending.firstIndex(where: { $0.id == x.id }) { cancel(k) }
                render(.pending, .status)
                return
            }
            if x.withdrawn == "timeout" {
                failed(x, x.kind == "prompt" ? "The Claude app didn't take it." : "The Claude app didn't stop the reply.")
                return
            }
            failed(x, (x.kind == "prompt" ? "The Claude app didn't take it" : "The Claude app didn't stop the reply")
                + (a.error.map { ": " + Self.oneLine($0, 200) } ?? "."))
            return
        }
        if x.kind == "interrupt" {
            checkLease()  // stopped (or nothing was running): the lease says idle by now
            return
        }
        guard let k = pending.firstIndex(where: { $0.id == x.id }) else { return }
        // Its turn started there: the bubble goes when the file has it (5 s at the latest).
        pending[k].started = true
        pending[k].state = "sending"
        doneSoon(x.id)
        syncSoon(0)
        render(.pending, .status)
    }

    /// A message the Claude app didn't run goes back in the composer, with why and Open in Claude.
    private func failed(_ x: BridgeSend, _ why: String) {
        if x.kind == "prompt" {
            guard let k = pending.firstIndex(where: { $0.id == x.id }) else { return }  // on file after all
            cancel(k)
        }
        error = why
        errorActions = lease?.entrypoint == "cli" ? [] : ["openInClaude"]
        render(.pending, .status)
    }

    /// Whether another Claude has this chat now, or has written to it since our claude's last turn (read now).
    private func otherHas(_ s: String) -> Bool {
        if Self.isOpen(s, ignoring: ClaudeProcess.runningPids()) { return true }
        return ourTail != nil && items.last?.id != ourTail
    }

    /// Whether a Claude has chat `id` open: the mod's lease (sync on or not), or the session registry.
    nonisolated private static func isOpen(_ id: String, ignoring ours: Set<Int32>) -> Bool {
        ClaudeBridge.lease(id)?.isChatHost == true || ChatIndex.liveSessions(ignoring: ours)[id] != nil
    }

    private static func isOpen(_ id: String) -> Bool { isOpen(id, ignoring: ClaudeProcess.runningPids()) }

    // MARK: The app chat went on under another id

    /// The id the Claude app chat goes on under now, if `s` was its current part and isn't any more (a rewind or
    /// /clear in the app made a new file), read now. nil if it hasn't moved, or `s` was only ever an earlier part.
    private func movedNow(_ s: String) -> String? {
        guard !ownRunning, let path = ChatIndex.shared.appChatFile(s) else { return nil }
        if ChatIndex.shared.isAppCurrent(s) { appCurrent = s }
        guard let r = ChatIndex.appPartNow(path: path, last: moveStat) else { return nil }
        moveStat = r
        return movedId(s, r)
    }

    private func movedId(_ s: String, _ r: AppPart) -> String? {
        guard let c = r.cli, !c.isEmpty else { return nil }
        if c == s {
            appCurrent = s
            return nil
        }
        guard appCurrent == s, r.prior.contains(s) else { return nil }
        return c
    }

    /// Every 4.5 s while the sticky shows: has the Claude app chat gone on under another id? If a Claude has that one
    /// open, the sticky follows it; else a banner asks (Open in Claude, Send here anyway).
    private func checkMoved() {
        guard let s = session, !checkingMove, lease == nil, live == nil, process == nil, stayHere != s,
              let path = ChatIndex.shared.appChatFile(s) else { return }
        if ChatIndex.shared.isAppCurrent(s) { appCurrent = s }
        guard appCurrent == s else { return }
        checkingMove = true
        let last = moveStat, ours = ClaudeProcess.runningPids()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = ChatIndex.appPartNow(path: path, last: last)
            let open = r?.cli.map { $0 != s && Self.isOpen($0, ignoring: ours) } ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.checkingMove = false
                    guard s == self.session, let r else { return }
                    self.moveStat = r
                    guard let c = self.movedId(s, r) else {
                        if self.movedTo != nil { self.movedTo = nil; self.render(.status) }
                        return
                    }
                    if open, self.process == nil {
                        self.follow(c)
                    } else if self.movedTo != c {
                        self.movedTo = c
                        self.render(.status)
                    }
                }
            }
        }
    }

    /// The Claude app chat this sticky shows goes on as `c` now: show it, and send to it, from here on.
    private func follow(_ c: String) {
        if let p = process, !stopping, !ownRunning {  // it holds the old part
            stopping = true
            p.stop()
        }
        setSession(c)
        appCurrent = c
        notice = "This chat went on in the Claude app (after a rewind or /clear there), so this sticky follows it now."
        ChatIndex.shared.refresh()
        checkLive()
        syncSoon(0)
        render(.status)
    }

    /// The bubble goes after the next sync `secs` from now, if the file hasn't shown the message by then.
    private func doneSoon(_ id: String, _ secs: Double = 5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed, let k = self.pending.firstIndex(where: { $0.id == id }),
                      self.pending[k].doneAt == nil else { return }
                self.pending[k].doneAt = self.syncSeq
                self.syncSoon(0)
            }
        }
    }

    /// Stop (or Esc): our claude's turn, or the Claude app's (when the mod can stop it). Messages that wait for our
    /// claude to restart come back to the composer, and so do the ones sent to the app that haven't started.
    private func stopReply() {
        if !restart.isEmpty {
            for m in restart { if let k = pending.firstIndex(where: { $0.id == m.uuid }) { cancel(k) } }
            restart = []
            restartCopy = false
            render(.pending, .status)
        }
        if let p = process, ownRunning {
            p.interrupt()
            return
        }
        guard let s = session else { return }
        leaseSeq += 1
        setLease(ClaudeBridge.lease(s))  // the turn running right now, not the one the last tick saw
        guard let l = lease, l.busy, l.canInterrupt else { return }
        // Messages the app hasn't started would run right after the stop: they come back instead. One the mod has
        // taken waits there for the turn to end; with its file gone it isn't sent, and its ack says so.
        for (id, x) in sends where x.kind == "prompt" {
            ClaudeBridge.withdraw(session: x.session, id: id)
            if x.claimed || ClaudeBridge.isClaimed(session: x.session, id: id) {
                sends[id]?.claimed = true
                sends[id]?.withdrawn = "stop"
                continue
            }
            ClaudeBridge.finish(session: x.session, id: id)
            sends[id] = nil
            if let k = pending.firstIndex(where: { $0.id == id }) { cancel(k) }
        }
        let id = Self.newId()
        do {
            // It names the turn to stop: if that one has ended by the time the mod reads this, nothing else stops.
            try ClaudeBridge.post(session: s, id: id, kind: "interrupt", text: "", turnId: l.turnId)
        } catch let e {
            error = e.localizedDescription
            render(.status)
            return
        }
        sends[id] = BridgeSend(id: id, session: s, kind: "interrupt", at: ProcessInfo.processInfo.systemUptime)
        watchAcks()
        render(.pending, .status)
    }

    /// A banner button the page hands back.
    private func act(_ id: String) {
        switch id {
        case "openInClaude": ClaudeApp.openChat(session)
        case "turnOnSync": onTurnOnSync?()
        case "dismissError":
            error = nil
            errorActions = []
            render(.status)
        default: break
        }
    }

    // MARK: A new chat moves to the Claude app

    /// A new chat Sticky started moves to the Claude app once our claude has quit after a reply, with Claude Code's own
    /// handoff (`claude --desktop --resume <id>`): same id, same file, and it's in the app's list from then on. The app
    /// opens it (it shows that chat once) and loads Sticky's mod, so later sends go to it. No folder question, no
    /// Return to press. If the app came forward, this sticky comes back on top.
    private func moveToApp() {
        guard let s = handoff, s == session, !handingOff, process == nil, !closed else { return }
        handoff = nil
        guard ClaudeSync.isOn, ClaudeApp.isInstalled else { return }
        handingOff = true
        let wasFront = NSApp.isActive
        let cwd = folder
        render(.status)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = ClaudeApp.handOff(session: s, cwd: cwd)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    self.handingOff = false
                    if r.ok {
                        self.movedAt = ProcessInfo.processInfo.systemUptime
                        self.appCurrent = s
                        self.notice = "This chat is in the Claude app now, too. Sends from here go to it."
                        ChatIndex.shared.refresh()  // the app's id for it (Open in Claude)
                        self.checkLease()
                        if wasFront { self.comeBackSoon() }
                    } else {
                        self.error = "Couldn't move this chat to the Claude app: \(r.message) It goes on here."
                    }
                    self.render(.status)
                }
            }
        }
    }

    /// The Claude app may come forward to show the chat that moved: this sticky comes back on top (only if Sticky was
    /// in front before, and the app is now).
    private func comeBackSoon() {
        for t in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.closed, !NSApp.isActive,
                          NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeApp.bundleId else { return }
                    self.onFront?()
                    self.focus()
                }
            }
        }
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
            let ours = turn || pending.contains { !$0.app && $0.doneAt == nil && $0.state != "cancelled" }
            cliTurn = true
            turn = true
            idleWork?.cancel()
            idleWork = nil
            if !ours, let p = process, !stopping, let s = session, otherHas(s) {
                // A turn of its own, while another Claude has the chat (or has written to it since our last turn):
                // this claude doesn't know what the other wrote, so its reply would go into a side branch. It stops.
                stopping = true
                p.stop()
                notice = "A background task in Sticky's claude finished while another Claude had this chat, so Sticky "
                    + "stopped its claude before it wrote next to that Claude."
            }
            render(.status)
        case .backgroundTasks(let n):
            bgTasks = n
            if n == 0 { scheduleIdle() }  // the few seconds start once the last one is done
        case .granted(let rules, let dirs):
            // Kept for the chat: the next claude (this one quits after each reply) starts with them.
            for r in rules where !grantRules.contains(r) { grantRules.append(r) }
            for d in dirs where !grantDirs.contains(d) { grantDirs.append(d) }
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
            // Messages that never ran won't now. The next send starts claude again. (Not the Claude app's, and not
            // the ones that waited for this exit: those start it again now.)
            let waiting = Set(restart.map(\.uuid))
            for k in pending.indices where pending[k].doneAt == nil && pending[k].state != "cancelled" && !pending[k].app
                && !waiting.contains(pending[k].id) {
                if pending[k].started { pending[k].doneAt = syncSeq } else { cancel(k) }
            }
            syncSoon(0)
            if !restart.isEmpty {
                restartAfterExit()
            } else if err == nil, let h = handoff, h == session, ChatIndex.findFile(h) != nil {
                moveToApp()  // a new chat: to the Claude app now that our claude has quit
            }
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

    /// A few seconds after a turn ends, with nothing queued and no card open, claude quits (not while it runs a
    /// background task: quitting would end it; it quits once the last one is done). Quitting writes where the chat
    /// ends, so whichever Claude opens it next goes on from there. The next message starts it again (--resume).
    private func scheduleIdle() {
        idleWork?.cancel()
        idleWork = nil
        guard process != nil, !ownRunning, cards.isEmpty, bgTasks == 0 else { return }
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let p = self.process, !self.stopping, !self.ownRunning, self.cards.isEmpty,
                      self.bgTasks == 0 else { return }
                self.stopping = true
                p.stop()
            }
        }
        idleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleExit, execute: w)
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

/// A message handed to the Claude app's chat through the bridge, not answered yet.
private struct BridgeSend {
    var id: String
    var session: String
    var kind: String           // prompt | interrupt
    var at: Double             // uptime when it was written
    var claimed = false        // a load of the mod has it
    var goneAt: Double?        // uptime since when the chat's lease has been gone, and no process has the chat
    var withdrawn: String?     // Sticky deleted it after the mod claimed it: "stop" | "timeout" (the mod acks ok:false)
    var claimers: Set<String> = []  // the loads of the mod that claimed it (from its claim files' names)
    var idleSince: Double?     // uptime since when the chat has been idle, once claimed
    var otherSince: Double?    // uptime since when another load than a claimer has held the chat, idle
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
    var app = false            // handed to the Claude app (through the bridge), not to our claude

    var js: [String: Any] { ["id": id, "text": text, "images": images, "state": state] }
}

/// A permission card: the request's input (an answer to a question sends it back) and the page's Perm.
private struct PermCard {
    var id: String
    var input: [String: Any]
    var js: [String: Any]
}
