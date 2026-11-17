// The list of every local Claude Code chat for ⌘O, cached, and which chats another Claude has open right now.
//
// A chat is ~/.claude/projects/<folder>/<id>.jsonl. Files can be 100+ MB, so it reads only the last and first
// 64 KB of each (a little further when those miss a prompt, time or title), and only again when the file's size
// or modified time changed.
// Titles and archived state come from the Claude app's own session list when it has one.
// It only reads Claude's files. It never writes them, and never opens the .key files next to the session list.
import Foundation
import Darwin

/// One chat in the list.
struct ChatSummary: Codable, Equatable {
    var id: String  // session id = file stem
    var path: String  // the .jsonl ("" if not on disk yet)
    var title: String  // best title, one line
    var cwd: String?  // folder to continue it in
    var firstPrompt: String  // cleaned, one line, ≤ 200 chars
    var lastPrompt: String  // cleaned, one line, ≤ 200 chars
    var created: Double?  // unix seconds
    var updated: Double  // last row timestamp, else file mtime
    var entrypoint: String?  // first entrypoint in the file: claude-desktop | cli | sdk-cli | sdk-ts
    var archived: Bool  // archived in the Claude app
    var size: Int64  // cache key
    var mtime: Double  // cache key
    var firstUuid: String? = nil  // uuid of the file's first transcript row; a fork copy starts with the same one
}

/// A chat that another Claude process has open right now.
struct LiveSession { var pid: Int32; var busy: Bool; var entrypoint: String?; var name: String? }

/// Every local Claude Code chat, newest first. Cached in ~/Library/Application Support/Sticky/chat-index.json.
@MainActor final class ChatIndex {
    static let shared = ChatIndex()

    /// Where the list is cached, where chats Sticky started are remembered, and the folders you said to trust in
    /// Sticky. Tests point these elsewhere first.
    static var cacheURL = supportDir.appendingPathComponent("chat-index.json")
    static var ownURL = supportDir.appendingPathComponent("chat-own.json")
    static var trustURL = supportDir.appendingPathComponent("chat-trust.json")
    private static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sticky")

    private(set) var chats: [ChatSummary] = []  // loaded from the cache at init (synchronously, fast), then kept fresh
    var onChange: (() -> Void)?  // after a refresh changed `chats` (main thread)
    var isRefreshing: Bool { running }
    /// How many chat files the last compose() left out, by reason ("copy", "headless", "noPrompt", "deleted"), and
    /// how many earlier parts of Claude app chats it listed ("earlierParts"). For checking the list.
    private(set) var stats: [String: Int] = [:]

    private var files: [String: ChatSummary] = [:]  // path → what that file says; `title` is the file's own title, "" if none
    private var desk = Desk()  // the Claude app's session list, as last read
    private var own: [String: Own] = [:]  // chats Sticky started
    private var index: [String: Int] = [:]  // id → position in `chats`
    private var appTitles: [String: String] = [:]  // jsonl id → the Claude app's title for that chat
    private var running = false
    private var again = false

    init() {
        if let data = try? Data(contentsOf: Self.ownURL),
           let o = try? JSONDecoder().decode([String: Own].self, from: data) {
            own = o
        }
        if let data = try? Data(contentsOf: Self.cacheURL),
           let c = try? JSONDecoder().decode(Cache.self, from: data), c.v == Reader.version {
            files = Dictionary(c.files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            desk = c.desk
        }
        compose()
    }

    // MARK: Refreshing

    /// Rescans in the background: only files whose size or mtime changed are re-read (head 64 KB + tail 64 KB, the tail
    /// widened when it holds no time, prompt or title, plus a stream-from-start fallback for the first prompt).
    /// Re-checks desktop metadata every time (re-reading the files that changed). Coalesces repeated calls.
    func refresh() {
        guard !running else { again = true; return }
        running = true
        let old = files, oldDesk = desk, url = Self.cacheURL
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Reader.rescan(old, oldDesk)
            if r.changed { Reader.writeCache(r, to: url) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(r) }
            }
        }
    }

    private func finish(_ r: Rescan) {
        files = r.files
        desk = r.desk
        running = false
        let before = chats
        pruneOwn()
        compose()
        if chats != before { onChange?() }
        if again {
            again = false
            refresh()
        }
    }

    func summary(_ id: String) -> ChatSummary? {
        index[id].map { chats[$0] }
    }

    /// The Claude app's title for this chat (it follows renames there), as last read.
    func appTitle(_ id: String) -> String? { appTitles[id] }

    // MARK: Chats Sticky started

    /// A chat Sticky started (the CLI marks those `sdk-cli`): list it anyway, with this title until the file has one.
    /// Persisted in ~/Library/Application Support/Sticky/chat-own.json. Adds a placeholder row at once.
    func markOwn(_ id: String, title: String?, cwd: String?) {
        guard !id.isEmpty else { return }
        let t = title.map { Reader.oneLine($0, 120) }.flatMap { $0.isEmpty ? nil : $0 }
        let o = own[id]
        own[id] = Own(title: t ?? o?.title, cwd: cwd ?? o?.cwd, t: o?.t ?? Date().timeIntervalSince1970)
        saveOwn()
        let before = chats
        compose()
        if chats != before { onChange?() }
        refresh()  // picks up the file as soon as the CLI writes it
    }

    private func saveOwn() {
        guard let data = try? JSONEncoder().encode(own) else { return }
        try? FileManager.default.createDirectory(at: Self.ownURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.ownURL, options: .atomic)
    }

    /// Forgets marks for chats that never got a file within a week (a send that failed, say).
    private func pruneOwn() {
        let ids = Set(files.values.map(\.id))
        let now = Date().timeIntervalSince1970
        let kept = own.filter { ids.contains($0.key) || now - $0.value.t < 7 * 86400 }
        if kept.count != own.count {
            own = kept
            saveOwn()
        }
    }

    // MARK: Building the list

    /// Applies the Claude app's titles, archived state and hidden copies, plus Sticky's own chats, to what the files say.
    private func compose() {
        var byCli: [String: DeskFile] = [:]  // the Claude app's entry for each jsonl id (newest activity wins)
        for f in desk.files.values {
            guard let c = f.cli, !c.isEmpty else { continue }
            if let o = byCli[c], o.active >= f.active { continue }
            byCli[c] = f
        }
        let ids = Set(files.values.map(\.id))
        let deleted = Set(desk.deleted)
        var byFileId: [String: ChatSummary] = [:]  // id → its file (the newer one if the id is in two folders)
        for f in files.values where byFileId[f.id].map({ $0.updated < f.updated }) ?? true { byFileId[f.id] = f }

        // A Claude app chat lists the files it had before its current one (priorCliSessionIds, oldest first). One
        // that starts with the same row as a newer file of the chat is a copy of it (a fork copies every row with its
        // uuid): hidden, the newest of them is listed. Any other is an earlier part of the chat (before a /clear or a
        // restart, say): listed on its own. A file that is itself some chat's current file is never hidden.
        var superseded = Set<String>()
        var earlier: [String: DeskFile] = [:]  // prior id → the chat it was an earlier part of
        for f in desk.files.values {
            guard let c = f.cli, !c.isEmpty else { continue }
            var starts = Set<String>()  // first-row uuids of newer files that are listed
            for id in ([c] + f.prior.reversed()) where id == c || byCli[id] == nil {
                guard let s = byFileId[id], !deleted.contains(id) else { continue }
                if id != c, let u = s.firstUuid, starts.contains(u) {
                    superseded.insert(id)
                    continue
                }
                if id != c, earlier[id].map({ $0.active < f.active }) ?? true { earlier[id] = f }
                if !s.firstPrompt.isEmpty || own[id] != nil, let u = s.firstUuid { starts.insert(u) }
            }
        }

        var byId: [String: ChatSummary] = [:]
        var titles: [String: String] = [:]
        var left: [String: Int] = [:]
        var parts = Set<String>()
        for var s in files.values {
            if deleted.contains(s.id) { left["deleted", default: 0] += 1; continue }
            let mine = own[s.id]
            if mine == nil {
                if superseded.contains(s.id) { left["copy", default: 0] += 1; continue }
                // Headless `claude -p` runs: one prompt each (scripts, tools). One with a later, other prompt is a
                // chat, and so is any from an SDK app (sdk-ts).
                if s.entrypoint == "sdk-cli", Self.samePrompt(s.firstPrompt, s.lastPrompt) {
                    left["headless", default: 0] += 1
                    continue
                }
                if s.firstPrompt.isEmpty { left["noPrompt", default: 0] += 1; continue }
            }
            let d = byCli[s.id]
            if let t = d?.title { titles[s.id] = t }
            let part = d == nil ? earlier[s.id] : nil
            // An earlier part with no title of its own: its chat's title, marked.
            let partTitle = s.title.isEmpty ? part?.title.map { Reader.oneLine($0, 104) + " (earlier part)" } : nil
            let t = [d?.title, partTitle, s.title, mine?.title, s.firstPrompt, s.lastPrompt]
                .lazy.compactMap { $0 }.first { !$0.isEmpty } ?? "New chat"
            s.title = t.count > 120 ? String(t.prefix(119)) + "…" : t
            s.archived = d?.archived ?? part?.archived ?? false
            if s.cwd == nil { s.cwd = d?.cwd ?? part?.cwd ?? mine?.cwd }
            if s.lastPrompt.isEmpty { s.lastPrompt = s.firstPrompt }
            if let o = byId[s.id], o.updated >= s.updated { continue }  // same id in two folders: the newer one
            byId[s.id] = s
            if part != nil { parts.insert(s.id) } else { parts.remove(s.id) }
        }
        // Sticky's own chats that have no file yet.
        for (id, m) in own where byId[id] == nil && !ids.contains(id) && !deleted.contains(id) {
            byId[id] = ChatSummary(id: id, path: "", title: m.title ?? "New chat", cwd: m.cwd, firstPrompt: "",
                                   lastPrompt: "", created: m.t, updated: m.t, entrypoint: "sdk-cli", archived: false,
                                   size: 0, mtime: 0)
        }
        chats = byId.values.sorted { $0.updated != $1.updated ? $0.updated > $1.updated : $0.id < $1.id }
        index = Dictionary(chats.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        appTitles = titles
        left["earlierParts"] = parts.count
        stats = left
    }

    /// The same prompt, maybe cut at another length (the first one is read from its row, the last one often from a
    /// last-prompt row, and each is cut to 200 characters on its own).
    private static func samePrompt(_ a: String, _ b: String) -> Bool {
        let x = a.hasSuffix("…") ? String(a.dropLast()) : a, y = b.hasSuffix("…") ? String(b.dropLast()) : b
        return x.hasPrefix(y) || y.hasPrefix(x)
    }

    // MARK: Claude's folders

    nonisolated static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// The folder name Claude uses for a cwd: every char outside [A-Za-z0-9] → "-" (per UTF-16 unit, like the CLI).
    nonisolated static func encode(_ cwd: String) -> String {
        let units = cwd.utf16.map { u -> UInt16 in
            (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) ? u : 45
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// ~/.claude/projects/*/<id>.jsonl (top level only). The newest one if the id is in two folders.
    nonisolated static func findFile(_ id: String) -> String? {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return nil }
        let root = projectsDir.path
        var best: (path: String, mtime: Double)?
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let p = root + "/" + folder + "/" + id + ".jsonl"
            guard let (_, m) = Reader.fileInfo(p) else { continue }
            if best == nil || m > best!.mtime { best = (p, m) }
        }
        return best?.path
    }

    // MARK: Live sessions

    /// Sessions open in another Claude process right now, keyed by session id, from ~/.claude/sessions/<pid>.json
    /// (files named only digits + ".json"; never the .key files). Alive = kill(pid,0)==0 and the process path
    /// (proc_pidpath) contains "claude". Skips `ignoring` pids (Sticky's own children).
    nonisolated static func liveSessions(ignoring: Set<Int32>) -> [String: LiveSession] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions").path
        var out: [String: LiveSession] = [:]
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".json") {
            let stem = n.dropLast(5)
            guard !stem.isEmpty, stem.utf8.count <= 9, stem.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let pid = Int32(stem), pid > 0, !ignoring.contains(pid) else { continue }
            guard kill(pid, 0) == 0, processPath(pid).lowercased().contains("claude") else { continue }
            guard let data = FileManager.default.contents(atPath: dir + "/" + n),
                  let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sid = d["sessionId"] as? String, !sid.isEmpty else { continue }
            if let p = (d["pid"] as? NSNumber)?.int32Value, p != pid { continue }  // a stale or copied file
            let name = (d["name"] as? String).map { Reader.oneLine($0, 120) }
            let s = LiveSession(pid: pid, busy: d["status"] as? String == "busy",
                                entrypoint: d["entrypoint"] as? String, name: name?.isEmpty == false ? name : nil)
            if let o = out[sid], o.busy || !s.busy { continue }  // two processes on one chat: the busy one
            out[sid] = s
        }
        return out
    }

    // MARK: Folder trust

    /// Whether Claude Code trusts this folder already, the way its own check goes: a projects[<path>]
    /// .hasTrustDialogAccepted in ~/.claude.json for the folder or one above it (inside a git repo, only up to the
    /// repo's top folder), or a folder you said to trust in Sticky. `claude -p` skips Claude's "Do you trust this
    /// folder?" question, so Sticky asks it before the folder's own settings, hooks and MCP servers can run.
    /// Only reads ~/.claude.json (its "projects" field), never writes it.
    static func isTrusted(_ cwd: String) -> Bool {
        var trusted = Set(stickyTrusted())
        let cfg = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json").path
        if let data = FileManager.default.contents(atPath: cfg) {
            let v = data.withUnsafeBytes { Reader.topFields(of: $0, ["projects"]) }
            for (k, x) in v["projects"] as? [String: Any] ?? [:]
            where (x as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true { trusted.insert(k) }
        }
        guard !trusted.isEmpty else { return false }
        for start in Set([standard(cwd), realPath(cwd)]) {
            var root: String?  // the git repo's top folder, if it's in one
            var d = start
            while true {
                if FileManager.default.fileExists(atPath: d + "/.git") { root = d; break }
                let up = (d as NSString).deletingLastPathComponent
                if up == d || up.isEmpty { break }
                d = up
            }
            var p = start
            while true {
                if trusted.contains(p) { return true }
                let up = (p as NSString).deletingLastPathComponent
                if p == root || up == p || up.isEmpty { break }
                p = up
            }
        }
        return false
    }

    /// Remembers that you trust this folder (and the folders in it), in Sticky's own chat-trust.json.
    static func trust(_ cwd: String) {
        var list = stickyTrusted()
        for p in [standard(cwd), realPath(cwd)] where !list.contains(p) { list.append(p) }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: trustURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: trustURL, options: .atomic)
    }

    private static func stickyTrusted() -> [String] {
        guard let data = try? Data(contentsOf: trustURL) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func standard(_ p: String) -> String {
        let s = URL(fileURLWithPath: p).standardizedFileURL.path
        return s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    private static func realPath(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return standard(p) }
        defer { free(r) }
        return String(cString: r)
    }

    private nonisolated static func processPath(_ pid: Int32) -> String {
        var buf = [UInt8](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
        let n = buf.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard n > 0 else { return "" }
        return String(decoding: buf[0..<Int(n)], as: UTF8.self)
    }
}

// MARK: - Cache and stored types

/// Sticky's own chats: the title to show until the file has one, and when it was started.
private struct Own: Codable { var title: String?; var cwd: String?; var t: Double }

/// One of the Claude app's session files (claude-code-sessions/…/local_<id>.json), as last read.
private struct DeskFile: Codable, Equatable {
    var size: Int64
    var mtime: Double
    var cli: String?  // cliSessionId: the jsonl id
    var title: String?
    var archived: Bool
    var prior: [String]  // priorCliSessionIds: older jsonl files of the same chat
    var cwd: String?
    var active: Double  // lastActivityAt, unix seconds
}

private struct Desk: Codable, Equatable {
    var files: [String: DeskFile] = [:]  // path → entry
    var deleted: [String] = []  // ids of deleted_<id> tombstones
}

private struct Cache: Codable {
    var v: Int
    var files: [ChatSummary]  // every chat file read, listed or not; `title` = the file's own title
    var desk: Desk
}

private struct Rescan {
    var files: [String: ChatSummary]
    var desk: Desk
    var changed: Bool
}

/// A chat file found on disk.
private struct Found {
    var path: String
    var id: String
    var folder: String
    var size: Int64
    var mtime: Double
}

// MARK: - Reading files (background)

private enum Reader {
    static let version = 2  // 2: ChatSummary.firstUuid
    static let chunk = 65536

    static var deskDir: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude-code-sessions").path
    }

    static func rescan(_ old: [String: ChatSummary], _ oldDesk: Desk) -> Rescan {
        let fm = FileManager.default
        let root = ChatIndex.projectsDir.path
        guard let folders = try? fm.contentsOfDirectory(atPath: root) else {
            // Can't read it right now: keep what we had rather than emptying the list.
            let desk = readDesk(oldDesk)
            return Rescan(files: old, desk: desk, changed: desk != oldDesk)
        }
        var found: [Found] = []
        for folder in folders {
            let dir = root + "/" + folder
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let suffix = ".desktop-released.json"
            let released = Set(names.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) })
            for n in names where n.hasSuffix(".jsonl") {
                let id = String(n.dropLast(6))
                guard !id.isEmpty, !id.hasPrefix("."), !released.contains(id) else { continue }
                let path = dir + "/" + n
                guard let (size, mtime) = fileInfo(path) else { continue }
                found.append(Found(path: path, id: id, folder: folder, size: size, mtime: mtime))
            }
        }
        var files: [String: ChatSummary] = [:]
        var todo: [Found] = []
        for f in found {
            if let o = old[f.path], o.size == f.size, abs(o.mtime - f.mtime) < 1e-6 {
                files[f.path] = o
            } else {
                todo.append(f)
            }
        }
        for (i, s) in parallel(todo.count, { readChat(todo[$0]) }).enumerated() {
            // A file that can't be opened right now keeps its old entry (stale keys, so it's tried again next time).
            if let s = s ?? old[todo[i].path] { files[todo[i].path] = s }
        }
        let desk = readDesk(oldDesk)
        return Rescan(files: files, desk: desk, changed: !todo.isEmpty || files.count != old.count || desk != oldDesk)
    }

    static func writeCache(_ r: Rescan, to url: URL) {
        let c = Cache(v: version, files: r.files.values.sorted { $0.path < $1.path }, desk: r.desk)
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Size and modified time of a regular file.
    static func fileInfo(_ path: String) -> (Int64, Double)? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return (Int64(st.st_size), Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
    }

    /// Runs `f(0..<n)` on all cores.
    static func parallel<T>(_ n: Int, _ f: (Int) -> T?) -> [T?] {
        var out = [T?](repeating: nil, count: n)
        guard n > 0 else { return out }
        out.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: n) { i in p[i] = f(i) }
        }
        return out
    }

    // MARK: One chat file

    /// What the list needs from one chat: the newest title, prompt, time and folder from the last 64 KB; the creation
    /// time and first prompt from the start (reading on only until the first prompt). nil if it can't be opened now.
    static func readChat(_ f: Found) -> ChatSummary? {
        var s = ChatSummary(id: f.id, path: f.path, title: "", cwd: nil, firstPrompt: "", lastPrompt: "", created: nil,
                            updated: f.mtime, entrypoint: nil, archived: false, size: f.size, mtime: f.mtime)
        let fd = open(f.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }  // not cached as "no prompt", so the next refresh tries it again
        defer { close(fd) }
        var t = Facts(folder: f.folder)
        let side = sidecarTitle(f)

        // The last 64 KB; then up to 1 MB back if that held no timestamp, prompt or custom title (a few huge rows,
        // say; a custom title outranks a newer ai-title or agent name); then up to 16 MB for a prompt (a long run
        // with no new prompt).
        var cut = f.size  // everything from here on has been read
        for span in [Int64(chunk), 1 << 20, 16 << 20] {
            let from = max(0, f.size - span)
            guard from < cut else { break }
            var buf = [UInt8]()
            append(fd, &buf, at: from, count: Int(cut - from))
            buf.withUnsafeBytes { p in
                for r in lines(p, dropFirst: from > 0).reversed() { t.tail(UnsafeRawBufferPointer(rebasing: p[r])) }
                if from == 0 {
                    cut = 0
                } else if let base = p.baseAddress, let nl = memchr(base, 0x0A, p.count) {
                    cut = from + Int64(base.distance(to: UnsafeRawPointer(nl))) + 1
                }
            }
            if t.updated != nil && t.lastPrompt != nil && (side != nil || t.custom != nil || span >= 1 << 20) { break }
        }
        stream(fd) { t.head($0) }
        t.finish()

        let title = [side, t.custom, t.ai, t.agent, t.legacy].lazy.compactMap { $0 }.first { !$0.isEmpty }
        s.title = title ?? ""
        s.cwd = t.reloc ?? t.match ?? t.headMatch ?? t.firstCwd ?? t.lastCwd
        s.firstPrompt = t.firstPrompt ?? ""
        s.lastPrompt = t.lastPrompt ?? ""
        s.created = t.created
        if let u = t.updated { s.updated = u }
        s.entrypoint = t.entry ?? t.lastEntry
        s.firstUuid = t.firstUuid
        return s
    }

    /// <folder>/<id>/custom-title.json: the cheapest title source.
    static func sidecarTitle(_ f: Found) -> String? {
        let p = (f.path as NSString).deletingLastPathComponent + "/" + f.id + "/custom-title.json"
        guard let data = FileManager.default.contents(atPath: p),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = d["customTitle"] as? String else { return nil }
        let s = oneLine(t, 120)
        return s.isEmpty ? nil : s
    }

    /// What one file says, gathered line by line.
    struct Facts {
        let folder: String
        // From the end, newest first.
        var custom: String?, ai: String?, agent: String?, legacy: String?
        var reloc: String?, lastPrompt: String?, updated: Double?
        var match: String?, lastCwd: String?, lastEntry: String?
        // From the start.
        var created: Double?, firstCwd: String?, entry: String?, firstPrompt: String?, headMatch: String?
        var firstUuid: String?, sawRow = false

        /// One line from the end of the file, newest first.
        mutating func tail(_ l: UnsafeRawBufferPointer) {
            if starts(l, "{\"parentUuid\":") {
                let wantRow = updated == nil || match == nil
                let wantPrompt = lastPrompt == nil && mayBePrompt(l)
                guard wantRow || wantPrompt, let d = parse(l) else { return }
                if updated == nil, let ts = d["timestamp"] as? String { updated = time(ts) }
                if let c = d["cwd"] as? String, !c.isEmpty {
                    if lastCwd == nil { lastCwd = c; lastEntry = d["entrypoint"] as? String }
                    if match == nil, ChatIndex.encode(c) == folder { match = c }
                }
                if wantPrompt { lastPrompt = promptText(d) }
            } else if starts(l, "{\"type\":\"") {
                if lastPrompt == nil, starts(l, "{\"type\":\"last-prompt\"") {
                    lastPrompt = (parse(l)?["lastPrompt"] as? String).flatMap(clean)
                } else if custom == nil, starts(l, "{\"type\":\"custom-title\"") {
                    custom = titleField(l, "customTitle")
                } else if ai == nil, starts(l, "{\"type\":\"ai-title\"") {
                    ai = titleField(l, "aiTitle")
                } else if agent == nil, starts(l, "{\"type\":\"agent-name\"") {
                    agent = titleField(l, "agentName")
                } else if legacy == nil, starts(l, "{\"type\":\"summary\"") {
                    legacy = titleField(l, "summary")
                } else if reloc == nil, starts(l, "{\"type\":\"relocated\"") {
                    reloc = (parse(l)?["relocatedCwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                } else if updated == nil, starts(l, "{\"type\":\"queue-operation\"") {
                    updated = (parse(l)?["timestamp"] as? String).flatMap(time)
                }
            }
        }

        /// One line from the start of the file. Returns false when nothing more is needed.
        mutating func head(_ l: UnsafeRawBufferPointer) -> Bool {
            if starts(l, "{\"parentUuid\":") {
                let first = !sawRow
                sawRow = true
                let wantRow = first || created == nil || firstCwd == nil || entry == nil || match == nil
                let wantPrompt = mayBePrompt(l)
                guard wantRow || wantPrompt, let d = parse(l) else { return true }
                if first { firstUuid = d["uuid"] as? String }
                if created == nil, let ts = d["timestamp"] as? String { created = time(ts) }
                if let c = d["cwd"] as? String, !c.isEmpty {
                    if firstCwd == nil { firstCwd = c }
                    if match == nil, ChatIndex.encode(c) == folder { headMatch = c }
                }
                if entry == nil { entry = d["entrypoint"] as? String }
                if wantPrompt, let p = promptText(d) {
                    firstPrompt = p
                    return false
                }
            } else if starts(l, "{\"type\":\"") {
                // Only when the end of the file had none (titles and moves are re-appended near the end as they change).
                if created == nil, starts(l, "{\"type\":\"queue-operation\"") {
                    created = (parse(l)?["timestamp"] as? String).flatMap(time)
                } else if starts(l, "{\"type\":\"custom-title\"") {
                    if custom == nil { headCustom = titleField(l, "customTitle") ?? headCustom }
                } else if starts(l, "{\"type\":\"ai-title\"") {
                    if ai == nil { headAi = titleField(l, "aiTitle") ?? headAi }
                } else if starts(l, "{\"type\":\"relocated\"") {
                    if reloc == nil { headReloc = parse(l)?["relocatedCwd"] as? String ?? headReloc }
                }
            }
            return true
        }
        var headCustom: String?, headAi: String?, headReloc: String?

        /// Folds in what only the start of the file had.
        mutating func finish() {
            if custom == nil { custom = headCustom }
            if ai == nil { ai = headAi }
            if reloc == nil, let r = headReloc, !r.isEmpty { reloc = r }
        }
    }

    static func titleField(_ l: UnsafeRawBufferPointer, _ key: String) -> String? {
        guard let t = parse(l)?[key] as? String else { return nil }
        let s = oneLine(t, 120)
        return s.isEmpty ? nil : s
    }

    // MARK: Prompts

    /// A user row that could be a typed prompt: not a tool result. Or a message typed while Claude was working.
    /// Cheap byte checks first, so the big tool-result rows are never parsed.
    static func mayBePrompt(_ l: UnsafeRawBufferPointer) -> Bool {
        if find(l, "\"type\":\"user\"", within: 1024) != nil {
            return find(l, "\"content\":[{\"tool_use_id\"", within: 1024) == nil
                && find(l, "\"content\":[{\"type\":\"tool_result\"", within: 1024) == nil
        }
        return find(l, "\"type\":\"queued_command\"", within: 1024) != nil
    }

    /// The prompt a person typed in this row, cleaned to one line; nil if the row isn't one.
    static func promptText(_ d: [String: Any]) -> String? {
        let type = d["type"] as? String
        if type == "attachment" {
            guard let a = d["attachment"] as? [String: Any], a["type"] as? String == "queued_command",
                  (a["commandMode"] as? String ?? "prompt") == "prompt", isHuman(a["origin"]) else { return nil }
            return text(a["prompt"]).flatMap(clean)
        }
        guard type == "user", d["isMeta"] as? Bool != true, d["isCompactSummary"] as? Bool != true,
              isHuman(d["origin"]), let m = d["message"] as? [String: Any] else { return nil }
        return text(m["content"]).flatMap(clean)
    }

    /// No origin (older and sdk rows) or a human one. Not task notifications or messages from other sessions.
    static func isHuman(_ o: Any?) -> Bool {
        guard let o = o as? [String: Any], let k = o["kind"] as? String else { return true }
        return k == "human"
    }

    /// The text of a string or a block list; nil if it holds a tool result.
    static func text(_ c: Any?) -> String? {
        if let s = c as? String { return s }
        guard let blocks = c as? [Any] else { return nil }
        var parts: [String] = []
        for case let b as [String: Any] in blocks {
            switch b["type"] as? String {
            case "tool_result": return nil
            case "text":
                if let t = b["text"] as? String, !t.hasPrefix("<system-reminder>") { parts.append(t) }
            default: break
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Strips reminders and app wrappers; nil for interruptions, commands, command output and notifications.
    static func clean(_ raw: String) -> String? {
        var t = raw
        if t.contains("<") {
            t = removeElements(t, "system-reminder")
            for w in ["artifact-view-context", "launch-selected-element", "create-pr-command"] { t = removeElements(t, w) }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("[Request interrupted by user") { return nil }
        let skip = ["<task-notification", "<scheduled-task", "<command-name>", "<command-message>", "<command-args>",
                    "<local-command-", "<bash-input>", "<bash-stdout>", "<bash-stderr>", "<user-prompt-submit-hook>"]
        if t.hasPrefix("<"), skip.contains(where: { t.hasPrefix($0) }) { return nil }
        if t.contains("<pasted_content") { t = unwrapPastes(t) }
        let s = oneLine(t, 200)
        return s.isEmpty ? nil : s
    }

    /// Removes every <name …>…</name> (to the end if it's never closed).
    static func removeElements(_ s: String, _ name: String) -> String {
        guard s.contains("<" + name) else { return s }
        var out = ""
        var rest = s[...]
        while let a = rest.range(of: "<" + name) {
            let next: Character = a.upperBound < rest.endIndex ? rest[a.upperBound] : ">"
            guard next == ">" || next == " " || next == "\n" else {  // a longer tag name: keep it
                out += rest[..<a.upperBound]
                rest = rest[a.upperBound...]
                continue
            }
            out += rest[..<a.lowerBound]
            if let b = rest.range(of: "</" + name + ">", range: a.upperBound..<rest.endIndex) {
                rest = rest[b.upperBound...]
            } else {
                rest = ""
            }
        }
        return out + rest
    }

    /// Keeps pasted text but drops the <pasted_content …> tags around it.
    static func unwrapPastes(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "</pasted_content>", with: " ")
        while let a = t.range(of: "<pasted_content"), let b = t.range(of: ">", range: a.upperBound..<t.endIndex) {
            t.replaceSubrange(a.lowerBound..<b.upperBound, with: " ")
        }
        return t
    }

    /// One line, whitespace collapsed, at most `max` characters (cut ones end in "…").
    static func oneLine(_ s: String, _ max: Int) -> String {
        let words = s.drop(while: \.isWhitespace).prefix(max * 4).split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let t = words.joined(separator: " ")
        return t.count > max ? String(t.prefix(max - 1)) + "…" : t
    }

    // MARK: Bytes and lines

    /// Reads `count` bytes at `offset` onto the end of `buf`. Returns how many were read.
    @discardableResult
    static func append(_ fd: Int32, _ buf: inout [UInt8], at offset: Int64, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let old = buf.count
        buf.append(contentsOf: repeatElement(0, count: count))
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + old, count, off_t(offset)) }
        buf.removeLast(count - max(n, 0))
        return max(n, 0)
    }

    /// The complete lines in `p` (without "\n"). The part after the last "\n" is partial (or being written), so it's
    /// left out; so is the part before the first "\n" when `dropFirst` (a read that started mid-line).
    static func lines(_ p: UnsafeRawBufferPointer, dropFirst: Bool) -> [Range<Int>] {
        guard let base = p.baseAddress else { return [] }
        var out: [Range<Int>] = []
        var s = 0
        var first = dropFirst
        while s < p.count, let nl = memchr(base + s, 0x0A, p.count - s) {
            let e = base.distance(to: UnsafeRawPointer(nl))
            if !first, e > s { out.append(s..<e) }
            first = false
            s = e + 1
        }
        return out
    }

    /// Calls `body` with each complete line from the start of the file, until it returns false or the file ends.
    /// Reads 64 KB first, then 1 MB at a time; a line can be any length.
    static func stream(_ fd: Int32, _ body: (UnsafeRawBufferPointer) -> Bool) {
        var buf = [UInt8]()
        var off: Int64 = 0
        var want = chunk
        while true {
            let n = append(fd, &buf, at: off, count: want)
            guard n > 0 else { return }
            off += Int64(n)
            want = 1 << 20
            var used = 0
            let stop = buf.withUnsafeBytes { p -> Bool in
                guard let base = p.baseAddress else { return false }
                while used < p.count, let nl = memchr(base + used, 0x0A, p.count - used) {
                    let e = base.distance(to: UnsafeRawPointer(nl))
                    if e > used, !body(UnsafeRawBufferPointer(start: base + used, count: e - used)) { return true }
                    used = e + 1
                }
                return false
            }
            if stop { return }
            buf.removeFirst(used)
        }
    }

    static func starts(_ l: UnsafeRawBufferPointer, _ s: StaticString) -> Bool {
        let n = s.utf8CodeUnitCount
        guard l.count >= n, let base = l.baseAddress else { return false }
        return memcmp(base, s.utf8Start, n) == 0
    }

    /// Where `s` first appears in the first `within` bytes of `l`.
    static func find(_ l: UnsafeRawBufferPointer, _ s: StaticString, within: Int) -> Int? {
        guard let base = l.baseAddress else { return nil }
        let n = Swift.min(l.count, within)
        guard let r = memmem(base, n, s.utf8Start, s.utf8CodeUnitCount) else { return nil }
        return base.distance(to: UnsafeRawPointer(r))
    }

    /// Parses one line without copying it.
    static func parse(_ l: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = l.baseAddress, l.count > 1 else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: l.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// "2026-01-02T03:04:05.678Z" → unix seconds. Hand-parsed (much faster than a date formatter).
    static func time(_ s: String) -> Double? {
        let u = Array(s.utf8)
        func num(_ a: Int, _ n: Int) -> Int? {
            guard a + n <= u.count else { return nil }
            var v = 0
            for i in a..<(a + n) {
                guard u[i] >= 48 && u[i] <= 57 else { return nil }
                v = v * 10 + Int(u[i] - 48)
            }
            return v
        }
        guard u.count >= 19, u[4] == 45, u[7] == 45, u[10] == 84 || u[10] == 32, u[13] == 58, u[16] == 58,
              var y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2),
              let se = num(17, 2), (1...12).contains(mo), (1...31).contains(d) else {
            return ISO8601DateFormatter().date(from: s)?.timeIntervalSince1970
        }
        var i = 19
        var frac = 0.0
        if i < u.count, u[i] == 46 {
            i += 1
            var scale = 0.1
            while i < u.count, u[i] >= 48 && u[i] <= 57 { frac += Double(u[i] - 48) * scale; scale /= 10; i += 1 }
        }
        var offset = 0
        if i < u.count, u[i] == 43 || u[i] == 45, let oh = num(i + 1, 2) {
            let om = (i + 3 < u.count && u[i + 3] == 58) ? num(i + 4, 2) ?? 0 : num(i + 3, 2) ?? 0
            offset = (oh * 3600 + om * 60) * (u[i] == 43 ? 1 : -1)
        }
        // Days since 1970 (Howard Hinnant's days_from_civil).
        if mo <= 2 { y -= 1 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Double(days * 86400 + h * 3600 + mi * 60 + se - offset) + frac
    }

    // MARK: The Claude app's session list

    /// claude-code-sessions/*/*/local_*.json and deleted_* tombstones. Only files whose size or mtime changed are read,
    /// and only their few top-level fields (the files hold up to MBs of MCP config, which is skipped, not parsed).
    static func readDesk(_ old: Desk) -> Desk {
        let fm = FileManager.default
        let root = deskDir
        var d = Desk()
        var todo: [(path: String, size: Int64, mtime: Double)] = []
        for a in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for b in (try? fm.contentsOfDirectory(atPath: root + "/" + a)) ?? [] {
                let dir = root + "/" + a + "/" + b
                for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                    if n.hasPrefix("deleted_") {
                        let id = String(n.dropFirst(8))
                        if !id.isEmpty { d.deleted.append(id) }
                    } else if n.hasPrefix("local_"), n.hasSuffix(".json") {
                        let p = dir + "/" + n
                        guard let (size, mtime) = fileInfo(p) else { continue }
                        if let o = old.files[p], o.size == size, abs(o.mtime - mtime) < 1e-6 {
                            d.files[p] = o
                        } else {
                            todo.append((p, size, mtime))
                        }
                    }
                }
            }
        }
        for (i, f) in parallel(todo.count, { deskFile(todo[$0].path, todo[$0].size, todo[$0].mtime) }).enumerated() {
            if let f { d.files[todo[i].path] = f }
        }
        d.deleted.sort()
        return d
    }

    static func deskFile(_ path: String, _ size: Int64, _ mtime: Double) -> DeskFile? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let want: Set<String> = ["cliSessionId", "title", "isArchived", "priorCliSessionIds", "cwd", "lastActivityAt"]
        let v = data.withUnsafeBytes { topFields(of: $0, want) }
        let title = (v["title"] as? String).map { oneLine($0, 120) }
        let prior = (v["priorCliSessionIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        let active = (v["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0
        return DeskFile(size: size, mtime: mtime, cli: v["cliSessionId"] as? String,
                        title: title?.isEmpty == false ? title : nil, archived: v["isArchived"] as? Bool ?? false,
                        prior: prior, cwd: (v["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }, active: active / 1000)
    }

    /// The wanted top-level fields of a JSON object. Every other value is skipped over without being parsed.
    static func topFields(of p: UnsafeRawBufferPointer, _ want: Set<String>) -> [String: Any] {
        var sc = Skipper(p: p)
        var out: [String: Any] = [:]
        sc.space()
        guard sc.at(0x7B) else { return out }  // {
        sc.i += 1
        while out.count < want.count {
            sc.space()
            guard sc.at(0x22), let k = sc.string() else { break }
            sc.space()
            guard sc.at(0x3A) else { break }  // :
            sc.i += 1
            sc.space()
            let start = sc.i
            guard sc.value() else { break }
            let key = String(decoding: UnsafeRawBufferPointer(rebasing: p[k]), as: UTF8.self)
            if want.contains(key), let base = p.baseAddress {
                let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: sc.i - start,
                                deallocator: .none)
                if let v = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) { out[key] = v }
            }
            sc.space()
            guard sc.at(0x2C) else { break }  // ,
            sc.i += 1
        }
        return out
    }

    /// Walks JSON bytes, jumping over strings and nested values.
    struct Skipper {
        let p: UnsafeRawBufferPointer
        var i = 0

        func at(_ c: UInt8) -> Bool { i < p.count && p[i] == c }

        mutating func space() {
            while i < p.count, p[i] == 0x20 || p[i] == 0x0A || p[i] == 0x0D || p[i] == 0x09 { i += 1 }
        }

        /// At a quote: moves past the string and returns the range inside the quotes.
        mutating func string() -> Range<Int>? {
            guard let base = p.baseAddress else { return nil }
            let open = i
            var j = i + 1
            while j < p.count, let q = memchr(base + j, 0x22, p.count - j) {
                let k = base.distance(to: UnsafeRawPointer(q))
                var b = k - 1
                var slashes = 0
                while b > open, p[b] == 0x5C { slashes += 1; b -= 1 }
                if slashes % 2 == 0 {
                    i = k + 1
                    return (open + 1)..<k
                }
                j = k + 1
            }
            return nil
        }

        /// Moves past one value of any kind.
        mutating func value() -> Bool {
            guard i < p.count else { return false }
            switch p[i] {
            case 0x22:
                return string() != nil
            case 0x7B, 0x5B:  // { [
                var depth = 0
                while i < p.count {
                    switch p[i] {
                    case 0x22:
                        guard string() != nil else { return false }
                        continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D:
                        depth -= 1
                        if depth == 0 { i += 1; return true }
                    default: break
                    }
                    i += 1
                }
                return false
            default:  // number, true, false, null
                let s = i
                while i < p.count, p[i] != 0x2C, p[i] != 0x7D, p[i] != 0x5D, p[i] > 0x20 { i += 1 }
                return i > s
            }
        }
    }
}
