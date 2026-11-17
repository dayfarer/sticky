// Runs one `claude` child process for a chat sticky and speaks its stream-json protocol over pipes.
//
// Everything stays on this Mac: no remote control, no skipping permission prompts, and "always allow"
// answers only last for this chat (destination "session"), so Claude's settings files never change.
import Foundation

/// One running `claude` for one chat, driven over pipes with the stream-json protocol.
final class ClaudeProcess: @unchecked Sendable {
    struct Options {
        var cwd: String
        var resume: String? = nil      // continue this session id (--resume)
        var fork: Bool = false         // with resume: continue it as a copy (--fork-session)
        var sessionId: String? = nil   // --session-id: the id of a new chat, or of the fork
        var mode: String? = nil        // --permission-mode (default | acceptEdits | plan | auto)
        var model: String? = nil       // --model
        var effort: String? = nil      // --effort
    }

    /// One block of the reply being written now.
    struct StreamBlock: Equatable {
        var messageId: String
        var index: Int
        var kind: String  // text | thinking | tool
        var text: String  // the text so far; for a tool, its input JSON so far
        var toolName: String?
    }

    /// Claude asks before it runs a tool.
    struct PermissionRequest {
        var id: String
        var toolName: String
        var displayName: String
        var input: [String: Any]
        var description: String?
        var reason: String?
        var blockedPath: String?
        var alwaysLabel: String?       // e.g. "Always allow `npm test` in this chat" / "Allow all edits in this chat"; nil = can't
        var needsAnswer: Bool          // requires_user_interaction (AskUserQuestion): answer with allow(updatedInput:)
        var agentId: String?
    }

    struct TurnResult {
        var isError: Bool
        var text: String?
        var reason: String?    // terminal_reason: completed | aborted_streaming | aborted_tools | api_error …
        var errors: [String]
        var costUSD: Double?   // the whole chat so far; nil when the CLI didn't say (it reports 0 after an interrupt)
    }

    enum Event {
        case sessionId(String)                       // the chat's id (hook events, system/init; a new one after /clear)
        case ready(models: [(value: String, label: String)], mode: String)   // reply to our initialize
        case lifecycle(uuid: String, state: String)  // queued | started | completed | cancelled for a message we sent
        case streaming([StreamBlock])                // the reply being written now (≤ every 40 ms); [] at message_stop
        case permission(PermissionRequest)
        case permissionCancelled(String)             // control_cancel_request: drop that card
        case turnStarted                             // system/init: a turn began (ours, or one claude starts itself)
        case turnEnded(TurnResult)
        case backgroundTasks(Int)                    // how many background tasks (shells, agents, monitors) run now
        case modeChanged(String)
        case modelChanged(String)
        case wrote                                   // a user/assistant/system row went by on stdout: the .jsonl probably grew
        case exited(code: Int32, error: String?)     // error: first errors[] of an error result, else the stderr tail, when code != 0
    }

    // MARK: Finding claude

    private static let lock = NSLock()
    private static let envLock = NSLock()  // held while the login shell runs, so two callers don't both start one
    private static var cachedEnv: [String: String]?
    private static var cachedClaude: String?
    private static var pids = Set<Int32>()

    /// Modes we pass on. Never bypassPermissions or dontAsk.
    private static let safeModes: Set<String> = ["default", "acceptEdits", "plan", "auto"]
    private static let efforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    /// The claude binary: ~/.local/bin/claude if executable, else found in the login-shell PATH. Cached.
    static func findClaude() -> String? {
        lock.lock()
        let c = cachedClaude
        lock.unlock()
        if let c { return c }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var found: String?
        if isProgram(home + "/.local/bin/claude") {
            found = home + "/.local/bin/claude"
        } else {
            for dir in (environment()["PATH"] ?? "").split(separator: ":") where isProgram(dir + "/claude") {
                found = dir + "/claude"
                break
            }
        }
        // Only a hit is cached, so installing Claude Code later works without restarting Sticky.
        if let found {
            lock.lock()
            cachedClaude = found
            lock.unlock()
        }
        return found
    }

    private static func isProgram(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// The child environment: this process's env minus CLAUDECODE, CLAUDE_CODE_* (but not the CLAUDE_CODE_DISABLE_* opt-outs
    /// or CLAUDE_CODE_USE_* provider switches), CLAUDE_AGENT_SDK*, BAGGAGE, TRACEPARENT, TRACESTATE; PATH = the login shell's PATH plus ~/.local/bin, /opt/homebrew/bin, /usr/local/bin; LANG default
    /// en_US.UTF-8. Cached. The first call can block ~1 s: call `warmUp()` at app launch.
    static func environment() -> [String: String] {
        envLock.lock()
        defer { envLock.unlock() }
        lock.lock()
        let cached = cachedEnv
        lock.unlock()
        if let cached { return cached }

        // Drop what would make claude think it runs inside another Claude Code session.
        var env = ProcessInfo.processInfo.environment.filter { k, _ in
            // Opt-outs and provider switches set for GUI apps (launchctl setenv) still apply.
            if k.hasPrefix("CLAUDE_CODE_DISABLE_") || k.hasPrefix("CLAUDE_CODE_USE_") { return true }
            return !(k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") || k.hasPrefix("CLAUDE_AGENT_SDK")
              || k == "BAGGAGE" || k == "TRACEPARENT" || k == "TRACESTATE")
        }
        if (env["LANG"] ?? "").isEmpty { env["LANG"] = "en_US.UTF-8" }
        // Started from Finder or a login item, Sticky only has launchd's bare PATH.
        var dirs = (loginPath(env) ?? env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for d in [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] where !dirs.contains(d) { dirs.append(d) }
        env["PATH"] = dirs.joined(separator: ":")

        lock.lock()
        cachedEnv = env
        lock.unlock()
        return env
    }

    /// Asks a login + interactive zsh for its PATH. rc files may print other text, so the answer follows a marker.
    private static func loginPath(_ env: [String: String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-i", "-c", "printf \"__STICKY_PATH__%s\" \"$PATH\""]
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        let got = Bytes()
        let ended = DispatchSemaphore(value: 0)
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; ended.signal() } else { got.append(d) }
        }
        do { try p.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        // At most 5 s. Once the shell is gone, give the pipe a moment (a background job may hold it open).
        let deadline = DispatchTime.now() + 5
        while DispatchTime.now() < deadline {
            if ended.wait(timeout: .now() + 0.1) == .success { break }
            if !p.isRunning {
                _ = ended.wait(timeout: .now() + 0.3)
                break
            }
        }
        if p.isRunning { p.terminate() }
        out.fileHandleForReading.readabilityHandler = nil
        let s = String(decoding: got.data, as: UTF8.self)
        guard let r = s.range(of: "__STICKY_PATH__", options: .backwards) else { return nil }
        let path = s[r.upperBound...].prefix { $0 != "\n" && $0 != "\r" }.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    /// Computes findClaude + environment on a background queue.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            _ = environment()
            _ = findClaude()
        }
    }

    /// Pids of every ClaudeProcess alive in this app (thread-safe).
    static func runningPids() -> Set<Int32> {
        lock.lock()
        defer { lock.unlock() }
        return pids
    }

    // MARK: State

    private let o: Options
    private let onEvent: @MainActor (Event) -> Void
    private let q = DispatchQueue(label: "sticky.claude.read")    // parsing and all protocol state
    private let wq = DispatchQueue(label: "sticky.claude.write")  // stdin writes, in order

    private let lock = NSLock()  // guards proc, alive, done
    private var proc: Process?
    private var alive = false
    private var done = false

    private var stdin: FileHandle?  // wq only

    // q only:
    private var buf: [UInt8] = []
    private var errTail = Data()
    private var nextId = 0
    private var calls: [String: (sub: String, value: String)] = [:]  // our control requests waiting for a reply
    private var asks: [String: [[String: Any]]] = [:]                // open permission ids → their session-only updates
    private var sent: [String: String] = [:]                         // our message uuids not done yet → lifecycle state
    private var session: String?
    private var mode: String?
    private var blocks: [StreamBlock] = []
    private var streamId = ""
    private var lastFlush = 0.0
    private var flushQueued = false
    private var streamGen = 0
    private var lastError: String?
    private var stopping = false
    private var inTurn = false  // system/init seen, its result not yet
    private var closeWhenTurnEnds = false
    private var eof = false
    private var ended = false
    private var code: Int32 = 0
    private var finished = false

    init(_ o: Options, onEvent: @escaping @MainActor (Event) -> Void) {
        self.o = o
        self.onEvent = onEvent
    }

    /// 0 before start.
    var pid: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return proc?.processIdentifier ?? 0
    }

    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return alive
    }

    // MARK: Starting

    private struct Failure: LocalizedError {
        var errorDescription: String?
    }

    private static func arguments(_ o: Options) -> [String] {
        var a = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                 "--include-partial-messages", "--permission-prompt-tool", "stdio"]
        if let r = o.resume, !r.isEmpty {
            a += ["--resume", r]
            if o.fork {
                a.append("--fork-session")
                // The CLI only takes --session-id with --resume when it's a fork.
                if let s = o.sessionId, !s.isEmpty { a += ["--session-id", s] }
            }
        } else if let s = o.sessionId, !s.isEmpty {
            a += ["--session-id", s]
        }
        // Always name the mode: without the flag a settings file's defaultMode applies (acceptEdits, even
        // bypassPermissions). The flag calls "default" "manual"; nil or an unsafe mode means "default".
        let m = o.mode.flatMap { safeModes.contains($0) ? $0 : nil } ?? "default"
        a += ["--permission-mode", m == "default" ? "manual" : m]
        if let m = o.model, !m.isEmpty { a += ["--model", m] }
        if let e = o.effort, efforts.contains(e) { a += ["--effort", e] }
        return a
    }

    /// Spawns `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
    /// --permission-prompt-tool stdio` + options, cwd = o.cwd, then sends `initialize`. Throws if claude is missing or the cwd is gone.
    func start() throws {
        lock.lock()
        let started = proc != nil
        lock.unlock()
        if started { return }
        // Writing to a claude that just died must not kill Sticky.
        signal(SIGPIPE, SIG_IGN)
        guard let exe = Self.findClaude() else {
            throw Failure(errorDescription: "Claude Code isn't installed: no `claude` in ~/.local/bin or your PATH.")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: o.cwd, isDirectory: &isDir), isDir.boolValue else {
            throw Failure(errorDescription: "This chat's folder is gone: \(o.cwd)")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)  // never through a shell: rc-file output would corrupt stdout
        p.arguments = Self.arguments(o)
        p.currentDirectoryURL = URL(fileURLWithPath: o.cwd, isDirectory: true)
        p.environment = Self.environment()
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        // Our ends must not leak into other children (a terminal sticky's forkpty keeps every open fd): a copy of
        // claude's stdin there would keep it from ever seeing EOF. Process's dup2 onto 0/1/2 clears the flag for claude.
        for pp in [inPipe, outPipe, errPipe] {
            for fd in [pp.fileHandleForReading.fileDescriptor, pp.fileHandleForWriting.fileDescriptor] {
                _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
            }
        }
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        // The handlers keep this object alive until the child is gone; finish() lets go of them.
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                self.q.async { self.stdoutEnded() }
            } else {
                self.q.async { self.feed(d) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.q.async {
                self.errTail.append(d)
                if self.errTail.count > 8192 { self.errTail = Data(self.errTail.suffix(8192)) }
            }
        }
        p.terminationHandler = { p in
            let c = p.terminationStatus
            self.q.async { self.childEnded(c) }
        }

        lock.lock()
        proc = p
        lock.unlock()
        do {
            try p.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            p.terminationHandler = nil
            lock.lock()
            proc = nil
            lock.unlock()
            throw error
        }
        lock.lock()
        if !done {
            alive = true
            Self.lock.lock()
            Self.pids.insert(p.processIdentifier)
            Self.lock.unlock()
        }
        lock.unlock()
        let h = inPipe.fileHandleForWriting
        wq.sync { stdin = h }
        q.async { self.call("initialize", ["hooks": NSNull()]) }
    }

    // MARK: Sending

    /// A user turn. Images go first, then the text. `uuid` gets lifecycle events.
    func send(_ text: String, images: [(mime: String, base64: String)], uuid: String) {
        var content: Any = text
        if !images.isEmpty {
            var parts: [[String: Any]] = images.map {
                ["type": "image", "source": ["type": "base64", "media_type": $0.mime, "data": $0.base64]]
            }
            if !text.isEmpty { parts.append(["type": "text", "text": text]) }
            content = parts
        }
        q.async {
            self.lock.lock()
            let up = self.proc != nil
            self.lock.unlock()
            // Nothing would read it (not started, stopping, or gone): say so, so it isn't shown as sending forever.
            guard up, !self.stopping, !self.finished else {
                self.emit(.lifecycle(uuid: uuid, state: "cancelled"))
                return
            }
            self.sent[uuid] = "sending"
            if !self.write(["type": "user", "message": ["role": "user", "content": content],
                            "parent_tool_use_id": NSNull(), "uuid": uuid]) {
                self.sent[uuid] = nil  // not valid JSON (text with a broken character): it never went out
                self.emit(.lifecycle(uuid: uuid, state: "cancelled"))
            }
        }
    }

    /// Lets the tool run. `always` also adds the request's suggested rules, folders and mode, for this chat only.
    func allow(_ id: String, updatedInput: [String: Any]? = nil, always: Bool = false) {
        q.async {
            guard let ups = self.asks.removeValue(forKey: id) else { return }  // already answered or withdrawn
            var body: [String: Any] = ["behavior": "allow"]
            if let u = updatedInput, JSONSerialization.isValidJSONObject(u) { body["updatedInput"] = u }
            var newMode: String?
            if always, !ups.isEmpty {
                body["updatedPermissions"] = ups
                newMode = ups.last { $0["type"] as? String == "setMode" }?["mode"] as? String
            }
            self.reply(id, body)
            if let m = newMode {
                self.mode = m
                self.emit(.modeChanged(m))
            }
        }
    }

    /// Says no. Claude sees `message`. `interrupt` also ends the turn.
    func deny(_ id: String, message: String, interrupt: Bool = false) {
        q.async {
            guard self.asks.removeValue(forKey: id) != nil else { return }
            let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
            var body: [String: Any] = ["behavior": "deny", "message": m.isEmpty ? "The user said no." : m]
            if interrupt { body["interrupt"] = true }
            self.reply(id, body)
        }
    }

    /// Stops the reply and drops messages waiting their turn.
    func interrupt() {
        q.async { self.call("interrupt", ["cancel_queued": true]) }
    }

    /// set_permission_mode → .modeChanged on success.
    func setMode(_ m: String) {
        guard Self.safeModes.contains(m) else { return }
        q.async { self.call("set_permission_mode", ["mode": m], value: m) }
    }

    /// set_model → .modelChanged(m) on success.
    func setModel(_ m: String) {
        guard !m.isEmpty else { return }
        q.async { self.call("set_model", ["model": m], value: m) }
    }

    /// Ends it politely: interrupt (if a turn is running), close stdin, SIGTERM after 3 s, SIGKILL after 6 s.
    func stop() {
        q.async {
            self.lock.lock()
            let p = self.proc
            self.lock.unlock()
            guard let p, !self.finished, !self.stopping else { return }
            self.stopping = true
            // Closing stdin alone lets a running turn carry on, so interrupt it first, and close once that
            // turn has ended (claude exits 1 if stdin closes while it winds down).
            if self.inTurn || !self.sent.isEmpty || !self.asks.isEmpty || !self.blocks.isEmpty {
                self.call("interrupt", ["cancel_queued": true])
                self.closeWhenTurnEnds = true
                self.q.asyncAfter(deadline: .now() + 1.5) { self.closeStdin() }
            } else {
                self.closeStdin()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    private func closeStdin() {
        closeWhenTurnEnds = false
        wq.async {
            try? self.stdin?.close()
            self.stdin = nil
        }
    }

    // MARK: Writing

    /// One JSON object + "\n". Anything that isn't valid JSON would kill claude, so it's never written (returns false).
    @discardableResult
    private func write(_ obj: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(obj),
              var d = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        d.append(10)
        wq.async {
            guard let h = self.stdin else { return }
            try? h.write(contentsOf: d)
        }
        return true
    }

    private func call(_ sub: String, _ fields: [String: Any], value: String = "") {
        nextId += 1
        let rid = "sticky-\(nextId)"
        calls[rid] = (sub, value)
        var req = fields
        req["subtype"] = sub
        write(["type": "control_request", "request_id": rid, "request": req])
    }

    private func reply(_ id: String, _ body: [String: Any]) {
        write(["type": "control_response",
               "response": ["subtype": "success", "request_id": id, "response": body] as [String: Any]])
    }

    private func emit(_ e: Event) {
        let f = onEvent
        DispatchQueue.main.async { MainActor.assumeIsolated { f(e) } }
    }

    // MARK: Reading

    /// Splits stdout on "\n" with no cap on line length (a line can be several MB).
    private func feed(_ d: Data) {
        guard !finished else { return }  // nothing goes out after .exited
        let from = buf.count
        buf.append(contentsOf: d)
        var start = 0
        var i = from
        while i < buf.count {
            let nl = buf.withUnsafeBufferPointer { b -> Int? in
                guard let base = b.baseAddress, let hit = memchr(base + i, 10, b.count - i) else { return nil }
                return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            }
            guard let nl else { break }
            if nl > start { line(buf[start..<nl]) }
            start = nl + 1
            i = start
        }
        if start > 0 { buf.removeFirst(start) }
    }

    private func line(_ bytes: ArraySlice<UInt8>) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any] else { return }
        handle(obj)
    }

    private func handle(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "stream_event":
            stream(obj)
        case "assistant", "user":
            // Subagent rows go to their own files, not the chat's .jsonl.
            if obj["parent_tool_use_id"] == nil || obj["parent_tool_use_id"] is NSNull { emit(.wrote) }
        case "system":
            system(obj)
        case "result":
            result(obj)
        case "control_request":
            controlRequest(obj)
        case "control_cancel_request":
            if let id = obj["request_id"] as? String, asks.removeValue(forKey: id) != nil {
                emit(.permissionCancelled(id))
            }
        case "control_response":
            controlResponse(obj)
        case "conversation_reset":
            // After /clear. Its new_conversation_id is that line's own uuid, not the new chat's id (no
            // .jsonl ever gets that name). The hook and init lines right after it carry the real id.
            break
        case "command_lifecycle":
            guard let u = obj["command_uuid"] as? String, let s = obj["state"] as? String else { return }
            if s == "completed" || s == "cancelled" { sent[u] = nil } else if sent[u] != nil { sent[u] = s }
            emit(.lifecycle(uuid: u, state: s))
        default:
            break
        }
    }

    private func seen(_ id: String) {
        guard !id.isEmpty, id != session else { return }
        session = id
        emit(.sessionId(id))
    }

    /// stdout-only system lines; the rest are rows in the .jsonl too.
    private static let quietSystem: Set<String> = ["init", "status", "thinking_tokens", "commands_changed", "hook_started",
                                                   "hook_progress", "hook_response", "task_progress"]

    private func system(_ obj: [String: Any]) {
        let sub = obj["subtype"] as? String ?? ""
        if sub == "init" || sub.hasPrefix("hook_"), let id = obj["session_id"] as? String { seen(id) }
        // Every turn starts with init and ends with a result: ours, and the ones claude starts by itself (a
        // background task finished, say).
        if sub == "init" {
            inTurn = true
            emit(.turnStarted)
        }
        // A plan approval and the like change the mode inside claude. A status line says so at once (mid-turn);
        // each turn's init says what it is now.
        if sub == "init" || sub == "status", let m = obj["permissionMode"] as? String, m != mode, mode != nil {
            mode = m
            emit(.modeChanged(m))
        }
        if sub == "background_tasks_changed", let tasks = obj["tasks"] as? [Any] { emit(.backgroundTasks(tasks.count)) }
        if !Self.quietSystem.contains(sub) { emit(.wrote) }
    }

    private func result(_ obj: [String: Any]) {
        inTurn = false
        if !blocks.isEmpty { endStream() }  // an interrupted reply has no message_stop
        let isError = obj["is_error"] as? Bool ?? false
        let errors = (obj["errors"] as? [Any])?.compactMap { $0 as? String } ?? []
        let text = obj["result"] as? String
        let cost = (obj["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0
        if isError {
            let real = errors.first { !$0.hasPrefix("[ede_diagnostic]") }
            if let e = real ?? ((text ?? "").isEmpty ? nil : text) { lastError = e }
        } else {
            lastError = nil
        }
        // Messages that ran in this turn are done, even if a queued one merged into it.
        for (u, s) in sent where s == "started" { sent[u] = nil }
        emit(.turnEnded(TurnResult(isError: isError, text: text,
                                   reason: obj["terminal_reason"] as? String ?? obj["subtype"] as? String,
                                   errors: errors, costUSD: cost > 0 ? cost : nil)))
        emit(.wrote)
        if closeWhenTurnEnds { closeStdin() }  // stop() is waiting for this turn
    }

    // MARK: Streaming

    private func stream(_ obj: [String: Any]) {
        if let p = obj["parent_tool_use_id"], !(p is NSNull) { return }  // a subagent
        guard let ev = obj["event"] as? [String: Any] else { return }
        let index = (ev["index"] as? NSNumber)?.intValue
        switch ev["type"] as? String {
        case "message_start":
            streamId = (ev["message"] as? [String: Any])?["id"] as? String ?? obj["api_message_id"] as? String ?? ""
            if !blocks.isEmpty { blocks = []; changed() }
        case "content_block_start":
            guard let index, let cb = ev["content_block"] as? [String: Any] else { return }
            let t = cb["type"] as? String ?? ""
            let kind = t == "text" ? "text" : t.contains("thinking") ? "thinking" : t.hasSuffix("tool_use") ? "tool" : ""
            guard !kind.isEmpty else { return }
            let text = kind == "text" ? cb["text"] as? String : kind == "thinking" ? cb["thinking"] as? String : nil
            blocks.removeAll { $0.index == index }
            blocks.append(StreamBlock(messageId: streamId, index: index, kind: kind, text: text ?? "",
                                      toolName: kind == "tool" ? cb["name"] as? String : nil))
            changed()
        case "content_block_delta":
            guard let index, let d = ev["delta"] as? [String: Any],
                  let k = blocks.lastIndex(where: { $0.index == index }) else { return }
            let add: String?
            switch d["type"] as? String {
            case "text_delta": add = d["text"] as? String
            case "thinking_delta": add = d["thinking"] as? String
            case "input_json_delta": add = d["partial_json"] as? String
            default: add = nil
            }
            guard let add, !add.isEmpty else { return }
            blocks[k].text += add
            changed()
        case "message_stop":
            endStream()
        default:
            break
        }
    }

    /// At most one .streaming every 40 ms, and the latest state always goes out.
    private func changed() {
        guard !flushQueued else { return }
        let wait = lastFlush + 0.04 - ProcessInfo.processInfo.systemUptime
        if wait <= 0 { flush(); return }
        flushQueued = true
        let gen = streamGen
        q.asyncAfter(deadline: .now() + wait) {
            guard gen == self.streamGen else { return }
            self.flushQueued = false
            self.flush()
        }
    }

    private func flush() {
        lastFlush = ProcessInfo.processInfo.systemUptime
        emit(.streaming(blocks))
    }

    /// The reply is done: the last unsent state goes out first, then [].
    private func endStream() {
        if flushQueued, !blocks.isEmpty { flush() }
        streamGen += 1
        flushQueued = false
        blocks = []
        emit(.streaming([]))
    }

    // MARK: Control messages

    private func controlRequest(_ obj: [String: Any]) {
        guard let id = obj["request_id"] as? String, let r = obj["request"] as? [String: Any] else { return }
        let sub = r["subtype"] as? String ?? ""
        guard sub == "can_use_tool" else {
            // We registered no hooks or SDK tools; say so, so claude doesn't wait for us.
            write(["type": "control_response",
                   "response": ["subtype": "error", "request_id": id, "error": "Sticky doesn't handle \(sub)"]])
            return
        }
        let tool = r["tool_name"] as? String ?? "tool"
        let display = (r["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tool
        let needs = r["requires_user_interaction"] as? Bool == true || tool == "AskUserQuestion"
        let ups = needs || r["suppress_always_allow_rule"] as? Bool == true
            ? [] : Self.sessionUpdates(r["permission_suggestions"])
        asks[id] = ups
        emit(.permission(PermissionRequest(
            id: id, toolName: tool, displayName: display, input: r["input"] as? [String: Any] ?? [:],
            description: r["description"] as? String, reason: r["decision_reason"] as? String,
            blockedPath: r["blocked_path"] as? String, alwaysLabel: ups.isEmpty ? nil : Self.label(ups, display),
            needsAnswer: needs, agentId: r["agent_id"] as? String)))
    }

    /// The request's suggestions, rebuilt with known fields only and destination "session" (other destinations make
    /// the CLI write settings files). Only allow rules, folders, and modes we pass on.
    private static func sessionUpdates(_ raw: Any?) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for s in raw as? [[String: Any]] ?? [] {
            switch s["type"] as? String {
            case "addRules":
                guard (s["behavior"] as? String ?? "allow") == "allow" else { continue }
                let rules: [[String: Any]] = (s["rules"] as? [[String: Any]] ?? []).compactMap { r in
                    guard let t = r["toolName"] as? String, !t.isEmpty else { return nil }
                    var c: [String: Any] = ["toolName": t]
                    if let rc = r["ruleContent"] as? String, !rc.isEmpty { c["ruleContent"] = rc }
                    return c
                }
                if !rules.isEmpty { out.append(["type": "addRules", "rules": rules, "behavior": "allow", "destination": "session"]) }
            case "addDirectories":
                let dirs = (s["directories"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
                if !dirs.isEmpty { out.append(["type": "addDirectories", "directories": dirs, "destination": "session"]) }
            case "setMode":
                if let m = s["mode"] as? String, safeModes.contains(m) {
                    out.append(["type": "setMode", "mode": m, "destination": "session"])
                }
            default:
                continue
            }
        }
        return out
    }

    /// The third button on a permission card. It names everything it grants (each rule, folder and mode), so
    /// "always" never lets in more than it says. nil when that's too long to show (the CLI drops the option then too).
    private static func label(_ ups: [[String: Any]], _ display: String) -> String? {
        var mode: String?
        var what: [String] = []
        for u in ups {
            switch u["type"] as? String {
            case "setMode": mode = u["mode"] as? String
            case "addRules":
                for r in u["rules"] as? [[String: Any]] ?? [] { what.append(ruleText(r, display)) }
            case "addDirectories":
                for d in u["directories"] as? [String] ?? [] { what.append("access to " + pathText(d, folder: true).text) }
            default: break
            }
        }
        var seen = Set<String>()
        what = what.filter { seen.insert($0).inserted }
        let list = what.count < 3 ? what.joined(separator: " and ")
                                  : what.dropLast().joined(separator: ", ") + " and " + what[what.count - 1]
        let s: String
        switch mode {
        case "acceptEdits": s = "Always allow all edits" + (list.isEmpty ? "" : " and " + list) + " in this chat"
        case let m?:
            let name = m == "default" ? "Ask first" : m
            s = "Allow and switch to \(name) mode" + (list.isEmpty ? "" : " (and always allow \(list) in this chat)")
        case nil: s = "Always allow \(list.isEmpty ? display : list) in this chat"
        }
        return s.count > 400 ? nil : s
    }

    /// One allow rule in words: "`npm test`", "reading files in `~/notes/`", "all edits".
    private static func ruleText(_ r: [String: Any], _ display: String) -> String {
        let tool = r["toolName"] as? String ?? display
        let c = (r["ruleContent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        func code(_ x: String) -> String { "`" + x.replacingOccurrences(of: "`", with: "'") + "`" }
        switch tool {
        case "Bash": return c.map(code) ?? "every command"
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            let read = tool == "Read"
            guard let c else { return read ? "reading any file" : "all edits" }
            let p = pathText(c)
            return (read ? "reading " : "editing ") + (p.folder ? "files in " : "") + p.text
        case "Glob", "Grep": return c.map { "searching in " + pathText($0, folder: true).text } ?? "searching any folder"
        case "WebFetch":
            guard let c else { return "opening any web page" }
            return c.hasPrefix("domain:") ? "opening pages on " + code(String(c.dropFirst(7))) : "WebFetch for " + code(c)
        default:
            var name = tool
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                if parts.count >= 2 { name = parts[0] + ": " + parts.dropFirst().joined(separator: " ") }
                name = name.replacingOccurrences(of: "_", with: " ")
            }
            return c.map { "\(name) for \(code($0))" } ?? name
        }
    }

    /// A rule's path as a code span: "//Users/me/notes/**" (an absolute path) → "`~/notes/`", a folder.
    private static func pathText(_ raw: String, folder: Bool = false) -> (text: String, folder: Bool) {
        var p = raw
        var isFolder = folder
        if p.hasPrefix("//") { p.removeFirst() }
        for g in ["/**", "/*", "**"] where p.hasSuffix(g) && p.count > g.count {
            p.removeLast(g.count)
            isFolder = true
            break
        }
        if p.hasPrefix("/") { p = (p as NSString).abbreviatingWithTildeInPath }
        if isFolder, !p.hasSuffix("/") { p += "/" }
        return ("`" + p.replacingOccurrences(of: "`", with: "'") + "`", isFolder)
    }

    private func controlResponse(_ obj: [String: Any]) {
        guard let r = obj["response"] as? [String: Any], let rid = r["request_id"] as? String,
              let c = calls.removeValue(forKey: rid), r["subtype"] as? String == "success" else { return }
        let body = r["response"] as? [String: Any] ?? [:]
        switch c.sub {
        case "initialize":
            let models: [(value: String, label: String)] = (body["models"] as? [[String: Any]] ?? []).compactMap { m in
                guard let v = m["value"] as? String, !v.isEmpty else { return nil }
                let l = m["displayName"] as? String ?? ""
                return (v, l.isEmpty ? v : l)
            }
            let m = body["current_permission_mode"] as? String ?? "default"
            mode = m
            emit(.ready(models: models, mode: m))
        case "set_permission_mode":
            let m = body["mode"] as? String ?? c.value
            mode = m
            emit(.modeChanged(m))
        case "set_model":
            emit(.modelChanged(c.value))  // what was picked ("sonnet"), not the resolved id
        default:
            break
        }
    }

    // MARK: Exit

    private func stdoutEnded() {
        if !finished, !buf.isEmpty {
            line(buf[...])
            buf = []
        }
        eof = true
        if ended { finish() }
    }

    private func childEnded(_ c: Int32) {
        ended = true
        code = c
        // Read what's left on stdout first, unless something else holds the pipe open.
        if eof { finish() } else { q.asyncAfter(deadline: .now() + 1) { self.finish() } }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        if !blocks.isEmpty { endStream() }
        lock.lock()
        done = true
        alive = false
        let p = proc
        lock.unlock()
        if let p {
            Self.lock.lock()
            Self.pids.remove(p.processIdentifier)
            Self.lock.unlock()
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            p.terminationHandler = nil
        }
        wq.async {
            try? self.stdin?.close()
            self.stdin = nil
        }
        for id in asks.keys.sorted() { emit(.permissionCancelled(id)) }
        asks = [:]
        sent = [:]
        var error: String?
        if code != 0 && !stopping {  // after stop() an exit is what we asked for, not an error
            let tail = String(decoding: errTail, as: UTF8.self)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .suffix(3).joined(separator: "\n")
            error = lastError ?? (tail.isEmpty ? "Claude stopped (exit code \(code))." : tail)
        }
        emit(.exited(code: code, error: error))
    }
}

/// Bytes collected from another thread.
private final class Bytes: @unchecked Sendable {
    private let lock = NSLock()
    private var d = Data()
    func append(_ x: Data) { lock.lock(); d.append(x); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return d }
}
