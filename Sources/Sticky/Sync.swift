// Syncs ~/Documents/Sticky Notes with the Sticky Notes web server (see web/).
// Config lives in ~/.config/sticky/sync.json: {"url": "https://…", "key": "…"} (mode 600).
//
// Rules: the server owns timestamps. Each note remembers the server version it last saw ("base")
// and the hash of the file at that point. A file whose hash changed is a local edit and gets
// pushed with its base; if the server changed in the meantime it keeps its version and stores
// ours as a "-conflict-" copy, so nothing is lost.
import AppKit
import CryptoKit

extension Notification.Name {
    static let stickyNoteFileChanged = Notification.Name("StickyNoteFileChanged")  // object: note id
    static let stickyNoteSaved = Notification.Name("StickyNoteSaved")
    static let stickySyncStatus = Notification.Name("StickySyncStatus")
}

@MainActor final class SyncEngine {
    static let shared = SyncEngine()

    struct Config: Codable { var url: String; var key: String }
    private struct Record: Codable { var base: Int64; var hash: String }
    private struct State: Codable {
        var lastPull: Int64 = 0
        var notes: [String: Record] = [:]
        var clientId: String?  // this Mac's ID, so the server knows our saves from other devices'
    }
    private struct ServerNote: Codable { let id: String; let body: String; let updatedAt: Int64; let deleted: Bool }
    private struct ListResponse: Codable { let notes: [ServerNote] }
    private struct WriteResponse: Codable { let note: ServerNote?; let copy: ServerNote? }

    enum SyncError: LocalizedError {
        case badKey, server(Int)
        var errorDescription: String? {
            switch self {
            case .badKey: return "The sync key was rejected"
            case .server(let c): return "Server error \(c)"
            }
        }
    }

    static let configFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sticky/sync.json")
    private static let stateFile = Store.file.deletingLastPathComponent().appendingPathComponent("sync-state.json")

    private(set) var config: Config?
    private var state = State()
    private var running = false
    private var runAgain = false
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private(set) var lastSuccess: Date?
    private(set) var lastError: String?

    var isConfigured: Bool { config != nil }

    // MARK: Lifecycle

    func start() {
        if let d = try? Data(contentsOf: Self.configFile), let c = try? JSONDecoder().decode(Config.self, from: d),
           !c.url.isEmpty, !c.key.isEmpty {
            config = Config(url: c.url.hasSuffix("/") ? String(c.url.dropLast()) : c.url, key: c.key)
        }
        if let d = try? Data(contentsOf: Self.stateFile), let s = try? JSONDecoder().decode(State.self, from: d) {
            state = s
        }
        guard config != nil else { return }
        if state.clientId == nil {
            state.clientId = "mac-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
            saveState()
        }

        // Fallback poll, plus a keepalive for the live connection.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                let me = SyncEngine.shared
                me.syncSoon(after: 0)
                if let s = me.socket { s.send(.string("ping")) { _ in } } else { me.connectLive() }
            }
        }
        NotificationCenter.default.addObserver(forName: .stickyNoteSaved, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SyncEngine.shared.syncSoon(after: 0.2) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                SyncEngine.shared.disconnectLive()
                SyncEngine.shared.connectLive()
                SyncEngine.shared.syncSoon(after: 3)
            }
        }
        connectLive()
        watchFolder()
        syncSoon(after: 1)
    }

    // MARK: Folder watching
    // Any change in the notes folder (Sticky's own saves, or another app editing a file) syncs at once.

    private var stream: FSEventStreamRef?

    private func watchFolder() {
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            MainActor.assumeIsolated { SyncEngine.shared.syncSoon(after: 0.3) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [NotesFolder.url.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    // MARK: Live updates
    // A WebSocket to the server; it pings us right after another device saves.

    private var socket: URLSessionWebSocketTask?
    private var socketRetry: TimeInterval = 1

    func connectLive() {
        guard socket == nil, let c = config, var parts = URLComponents(string: c.url + "/api/live") else { return }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.queryItems = [URLQueryItem(name: "client", value: state.clientId)]
        guard let url = parts.url else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(c.key)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        socket = task
        task.resume()
        listen(task)
    }

    func disconnectLive() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { result in
            Task { @MainActor in
                let me = SyncEngine.shared
                guard task === me.socket else { return }
                switch result {
                case .success(let message):
                    me.socketRetry = 1
                    if case .string(let text) = message, text.contains("changed") { me.syncSoon(after: 0) }
                    me.listen(task)
                case .failure:
                    me.socket = nil
                    let wait = me.socketRetry
                    me.socketRetry = min(me.socketRetry * 2, 60)
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                        MainActor.assumeIsolated { SyncEngine.shared.connectLive() }
                    }
                }
            }
        }
    }

    func syncSoon(after delay: TimeInterval) {
        guard config != nil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { Task { @MainActor in await SyncEngine.shared.sync() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    var statusText: String {
        guard isConfigured else { return "Sync: not set up" }
        if let e = lastError { return "Sync: \(e)" }
        guard let t = lastSuccess else { return "Sync: starting…" }
        let s = Int(Date().timeIntervalSince(t))
        return s < 60 ? "Synced just now" : "Synced \(s / 60) min ago"
    }

    // MARK: Sync

    func sync() async {
        guard config != nil else { return }
        if running { runAgain = true; return }
        running = true
        defer {
            running = false
            saveState()
            NotificationCenter.default.post(name: .stickySyncStatus, object: nil)
            if runAgain { runAgain = false; syncSoon(after: 0.5) }
        }
        do {
            try await pull()
            try await push()
            lastSuccess = Date()
            lastError = nil
        } catch let e as URLError where e.code == .notConnectedToInternet || e.code == .networkConnectionLost {
            lastError = "offline"
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func pull() async throws {
        let (code, data) = try await request("GET", "/api/notes?since=\(state.lastPull)")
        guard code == 200 else { throw SyncError.server(code) }
        let list = try JSONDecoder().decode(ListResponse.self, from: data)
        for n in list.notes {
            state.lastPull = max(state.lastPull, n.updatedAt)
            guard Self.validID(n.id), !isEditing(n.id) else { continue }
            let url = fileURL(n.id)
            let rec = state.notes[n.id]
            let local = try? Data(contentsOf: url)
            let localHash = local.map(Self.hash)
            // Changed here since the last sync? (A file we never synced counts as changed.)
            let localChanged = local != nil ? localHash != rec?.hash : rec != nil

            if n.deleted {
                if local != nil, !localChanged {
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    state.notes[n.id] = nil
                    announce(n.id)
                } else if local == nil {
                    state.notes[n.id] = nil
                }
                continue
            }
            let serverHash = Self.hash(n.body)
            if local == nil {
                if rec == nil {  // new note from another device
                    write(n.id, n.body)
                    state.notes[n.id] = Record(base: n.updatedAt, hash: serverHash)
                }
                continue  // otherwise: deleted here, the push step sends the delete
            }
            if !localChanged {
                if localHash != serverHash { write(n.id, n.body) }
                state.notes[n.id] = Record(base: n.updatedAt, hash: serverHash)
            } else if localHash == serverHash {
                state.notes[n.id] = Record(base: n.updatedAt, hash: serverHash)
            }
            // Both sides changed: push sends ours with the old base, and the server makes a copy.
        }
    }

    private func push() async throws {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: NotesFolder.url, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" }

        for url in files {
            let id = url.lastPathComponent
            guard Self.validID(id), !isEditing(id), let data = try? Data(contentsOf: url),
                  let body = String(data: data, encoding: .utf8) else { continue }
            let h = Self.hash(data)
            let rec = state.notes[id]
            if rec?.hash == h { continue }
            if rec == nil, body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

            let payload = try JSONSerialization.data(withJSONObject: [
                "body": body,
                "base": rec.map { NSNumber(value: $0.base) } ?? NSNull(),
                "client": state.clientId ?? "",
            ])
            let (code, resp) = try await request("PUT", "/api/notes/\(Self.encode(id))", body: payload)
            let r = try? JSONDecoder().decode(WriteResponse.self, from: resp)
            if code == 200, let n = r?.note {
                state.notes[id] = Record(base: n.updatedAt, hash: h)
            } else if code == 409, let n = r?.note {
                // The other device's version stays; ours now lives on the server as a copy.
                write(id, n.body)
                state.notes[id] = Record(base: n.updatedAt, hash: Self.hash(n.body))
                if let c = r?.copy {
                    write(c.id, c.body)
                    state.notes[c.id] = Record(base: c.updatedAt, hash: Self.hash(c.body))
                }
            } else {
                throw SyncError.server(code)
            }
        }

        // Notes deleted on this Mac.
        for (id, rec) in state.notes where !fm.fileExists(atPath: fileURL(id).path) {
            let (code, resp) = try await request("DELETE", "/api/notes/\(Self.encode(id))?base=\(rec.base)&client=\(state.clientId ?? "")")
            if code == 200 {
                state.notes[id] = nil
            } else if code == 409, let n = (try? JSONDecoder().decode(WriteResponse.self, from: resp))?.note {
                // Edited on another device after we last saw it: bring it back instead of deleting.
                write(id, n.body)
                state.notes[id] = Record(base: n.updatedAt, hash: Self.hash(n.body))
            } else {
                throw SyncError.server(code)
            }
        }
    }

    // MARK: Helpers

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> (Int, Data) {
        guard let c = config, let url = URL(string: c.url + path) else { throw SyncError.server(0) }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 20
        r.setValue("Bearer \(c.key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw SyncError.badKey }
        return (code, data)
    }

    private func fileURL(_ id: String) -> URL { NotesFolder.url.appendingPathComponent(id) }

    private func write(_ id: String, _ body: String) {
        try? body.write(to: fileURL(id), atomically: true, encoding: .utf8)
        announce(id)
    }

    private func announce(_ id: String) {
        NotificationCenter.default.post(name: .stickyNoteFileChanged, object: id)
    }

    /// A note open in an editor with unsaved typing: leave it alone until it saves.
    private func isEditing(_ id: String) -> Bool {
        NoteEditor.open.contains { $0.noteID == id && $0.hasUnsavedChanges }
    }

    private func saveState() {
        if let d = try? JSONEncoder().encode(state) { try? d.write(to: Self.stateFile) }
    }

    static func validID(_ id: String) -> Bool {
        id.count <= 200 && id.lowercased().hasSuffix(".md") && !id.hasPrefix(".") && !id.contains("/") && !id.contains("\\")
    }

    private static func encode(_ id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ s: String) -> String { hash(Data(s.utf8)) }

    // MARK: Phone setup

    func copyKeyForPhone() {
        guard let key = config?.key else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(key, forType: .string)
        let count = pb.changeCount
        // Don't leave the key on the clipboard: clear it after 2 minutes if it's still there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }
}
