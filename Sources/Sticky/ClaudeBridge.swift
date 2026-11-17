// Sticky's side of "Sync with Claude App": a small mod (sticky-bridge) runs inside the Claude app's own chat
// processes and sends what Sticky leaves for it as your own message, in the chat the app shows. All of it is files
// in one folder on this Mac: no network, no Remote Control, no cloud.
//
// The bridge folder (~/Library/Application Support/Sticky/bridge, 0700, or $STICKY_BRIDGE_DIR for tests):
//   leases/<sessionId>.json                      the mod: "this chat is open here" (every 3 s, and at each turn)
//   outbox/<sessionId>/<id>.json                 Sticky: a message, written whole (a temp file, then renamed)
//   outbox/<sessionId>/<id>.json.<loadId>.taken  the mod: its claim (the earliest claim wins, so nothing runs twice)
//   acks/<id>.json                               the mod: taken (its turn started) or not, and why
//   log.txt                                      the mod: one line per action (ids and states, never message text)
// The mod can't delete files, so Sticky deletes what it has read (the message, its claims, the ack) and sweeps
// leftovers after a day. To take a message back Sticky deletes its file: the mod never runs a message whose file is
// gone (it acks it ok:false), and refuses one first seen more than 8 s after it was written. Sticky never follows a
// link in there, and reads only small files.
import AppKit
import Darwin

extension Notification.Name {
    /// Sync with Claude App was turned on or off.
    static let stickyClaudeSync = Notification.Name("StickyClaudeSync")
}

/// What the mod says about one chat it has open.
struct BridgeLease: Equatable {
    var sessionId: String
    var entrypoint: String    // claude-desktop (the Claude app) | cli (a terminal) | …
    var state: String         // idle | turn | ended
    var updatedAt: Double     // ms since 1970
    var loadedAt: Double
    var loadId: String
    var canInterrupt: Bool    // the mod can stop the running turn ("interrupt" messages)
    var mod: String           // the mod's version ("" from a mod older than 1.0.0)
    var turnId: String? = nil // the turn running now (mod 1.1.0 and later): an "interrupt" names it

    var busy: Bool { state == "turn" }
    /// A chat you'd send to: the Claude app's, or a terminal claude's.
    var isChatHost: Bool { entrypoint == "claude-desktop" || entrypoint == "cli" }
    /// Not ended, and written in the last 10 s.
    func isLive(nowMs: Double) -> Bool {
        state != "ended" && abs(nowMs - updatedAt) <= ClaudeBridge.liveWindow * 1000
    }
}

/// The mod's answer to one outbox message.
struct BridgeAck {
    var id: String
    var ok: Bool
    var error: String?
    var at: Double?
    var stopped: Bool?        // an interrupt's: a turn was running and it stopped it (false: nothing was running)
}

/// The bridge folder: leases, the outbox and acks. Thread-safe (no state of its own); every call is a few small
/// file operations.
enum ClaudeBridge {
    /// A lease written longer ago than this is a chat no one has open any more.
    static let liveWindow = 10.0
    /// The biggest message file Sticky writes (the mod refuses bigger ones).
    static let maxMessageBytes = 1 << 20
    private static let maxLeaseBytes = 64 << 10
    private static let maxAckBytes = 1 << 20

    /// ~/Library/Application Support/Sticky/bridge, or $STICKY_BRIDGE_DIR (an absolute path; the mod honors it too).
    static let dir: String = {
        if let d = ProcessInfo.processInfo.environment["STICKY_BRIDGE_DIR"], d.hasPrefix("/"), !d.contains("/../") {
            return d.count > 1 && d.hasSuffix("/") ? String(d.dropLast()) : d
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sticky/bridge").path
    }()

    struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// The mod's names: a letter or digit, then letters, digits, ".", "_" or "-", 128 at most.
    static func isSafeName(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard !u.isEmpty, u.count <= 128, !s.contains("..") else { return false }
        func ok(_ c: UInt8, first: Bool) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (!first && (c == 46 || c == 95 || c == 45))
        }
        return u.enumerated().allSatisfy { ok($1, first: $0 == 0) }
    }

    private static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    // MARK: Leases

    /// The mod's live lease for this chat: not ended, and written in the last 10 s. nil if there's none. A lease
    /// that doesn't parse may be half written (the mod writes it in place): it's read again, up to 3 times.
    static func lease(_ sessionId: String) -> BridgeLease? {
        guard isSafeName(sessionId) else { return nil }
        let p = dir + "/leases/" + sessionId + ".json"
        for attempt in 0..<3 {
            guard let d = readSmall(p, max: maxLeaseBytes) else { return nil }
            if let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                guard let l = parseLease(o, sessionId) else { return nil }
                return l.isLive(nowMs: nowMs) ? l : nil
            }
            if attempt < 2 { usleep(30_000) }
        }
        return nil
    }

    static func parseLease(_ o: [String: Any], _ sessionId: String) -> BridgeLease? {
        if let v = o["v"] as? NSNumber, v.intValue != 1 { return nil }  // a format this Sticky doesn't know
        guard o["sessionId"] as? String == sessionId, let state = o["state"] as? String,
              ["idle", "turn", "ended"].contains(state), let at = (o["updatedAt"] as? NSNumber)?.doubleValue else { return nil }
        return BridgeLease(sessionId: sessionId, entrypoint: o["entrypoint"] as? String ?? "",
                           state: state, updatedAt: at, loadedAt: (o["loadedAt"] as? NSNumber)?.doubleValue ?? 0,
                           loadId: o["loadId"] as? String ?? "", canInterrupt: o["canInterrupt"] as? Bool ?? false,
                           mod: o["mod"] as? String ?? "",
                           turnId: (o["turnId"] as? String).flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 })
    }

    // MARK: The outbox

    /// Leaves a message for the mod in this chat's outbox: {v:1, id, kind, text}, written whole. `kind` is
    /// "prompt" or "interrupt"; an interrupt names the turn it stops (`turnId`, from the lease; a mod older than
    /// 1.1.0 has none and stops whatever runs).
    static func post(session: String, id: String, kind: String, text: String, turnId: String? = nil) throws {
        guard isSafeName(session), isSafeName(id) else { throw Failure("That chat's id can't go through the bridge.") }
        var obj: [String: Any] = ["v": 1, "id": id, "kind": kind, "text": text]
        if let t = turnId { obj["turnId"] = t }
        guard JSONSerialization.isValidJSONObject(obj), let data = try? JSONSerialization.data(withJSONObject: obj) else {
            throw Failure("That message can't be sent as it is.")
        }
        guard data.count <= maxMessageBytes else {
            throw Failure("That message is too long to send to the Claude app (1 MB at most).")
        }
        let box = dir + "/outbox/" + session
        try makeFolders()
        try makeDir(box)
        try writeWhole(box, id + ".json", data)
    }

    /// The bridge folder and the folders in it the mod writes into (each 0700). The mod never makes a folder, so it
    /// writes nothing until these are here.
    static func makeFolders() throws {
        try? FileManager.default.createDirectory(atPath: (dir as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        for d in [dir, dir + "/leases", dir + "/acks", dir + "/outbox"] { try makeDir(d) }
    }

    /// The mod's answer to message `id`, once it's there and whole.
    static func ack(_ id: String) -> BridgeAck? {
        guard isSafeName(id), let d = readSmall(dir + "/acks/" + id + ".json", max: maxAckBytes),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        if let other = o["id"] as? String, other != id { return nil }
        guard let ok = o["ok"] as? Bool else { return nil }
        let e = (o["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return BridgeAck(id: id, ok: ok, error: e, at: (o["at"] as? NSNumber)?.doubleValue, stopped: o["stopped"] as? Bool)
    }

    /// Whether a load of the mod has claimed message `id` (it will run it, or has).
    static func isClaimed(session: String, id: String) -> Bool { !claimers(session: session, id: id).isEmpty }

    /// The load ids of the mod that claimed message `id` (from its <id>.json.<loadId>.taken files).
    static func claimers(session: String, id: String) -> [String] {
        guard isSafeName(session), isSafeName(id) else { return [] }
        let pre = id + ".json.", post = ".taken"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir + "/outbox/" + session)) ?? [])
            .filter { $0.hasPrefix(pre) && $0.hasSuffix(post) && $0.count > pre.count + post.count }
            .map { String($0.dropFirst(pre.count).dropLast(post.count)) }
    }

    /// Takes message `id` back before the mod claims it.
    static func withdraw(session: String, id: String) {
        guard isSafeName(session), isSafeName(id) else { return }
        unlinkFile(dir + "/outbox/" + session + "/" + id + ".json")
    }

    /// Message `id` is done: deletes it, its claims and its ack (in that order: the mod never acts on an id that
    /// has an ack, and never takes a file that has a claim).
    static func finish(session: String, id: String) {
        guard isSafeName(session), isSafeName(id) else { return }
        let box = dir + "/outbox/" + session
        unlinkFile(box + "/" + id + ".json")
        let pre = id + ".json."
        for n in (try? FileManager.default.contentsOfDirectory(atPath: box)) ?? [] where n.hasPrefix(pre) && n.hasSuffix(".taken") {
            unlinkFile(box + "/" + n)
        }
        unlinkFile(dir + "/acks/" + id + ".json")
        rmdir(box)  // only if it's empty now
    }

    /// Deletes outbox messages, claims, acks and leases last changed more than `age` seconds ago, and outbox
    /// folders left empty. Never follows a link.
    static func sweep(olderThan age: Double = 86400) {
        let cut = Date().timeIntervalSince1970 - age
        func old(_ p: String) -> Bool {
            var st = stat()
            guard lstat(p, &st) == 0 else { return false }
            let kind = st.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFLNK else { return false }
            return Double(st.st_mtimespec.tv_sec) < cut
        }
        let fm = FileManager.default
        for sub in ["acks", "leases"] {
            let d = dir + "/" + sub
            guard isRealDir(d) else { continue }
            for n in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where old(d + "/" + n) { unlinkFile(d + "/" + n) }
        }
        let out = dir + "/outbox"
        guard isRealDir(out) else { return }
        for s in (try? fm.contentsOfDirectory(atPath: out)) ?? [] {
            let box = out + "/" + s
            guard isRealDir(box) else {
                if old(box) { unlinkFile(box) }
                continue
            }
            for n in (try? fm.contentsOfDirectory(atPath: box)) ?? [] where old(box + "/" + n) { unlinkFile(box + "/" + n) }
            rmdir(box)
        }
    }

    // MARK: Files

    /// Makes the folder (0700), or checks the one there: a real folder (not a link) of this user, 0700.
    static func makeDir(_ p: String) throws {
        if mkdir(p, 0o700) == 0 { return }
        guard errno == EEXIST else { throw Failure("Couldn't make the bridge folder (\(String(cString: strerror(errno)))).") }
        var st = stat()
        guard lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else {
            throw Failure("The bridge folder isn't a plain folder of yours: \((p as NSString).abbreviatingWithTildeInPath)")
        }
        if st.st_mode & 0o077 != 0 { chmod(p, 0o700) }
    }

    private static func isRealDir(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// A plain file of at most `max` bytes (never through a link), else nil.
    static func readSmall(_ p: String, max: Int) -> Data? {
        let fd = open(p, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= off_t(max) else { return nil }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while out.count <= max {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            out.append(buf, count: n)
        }
        return out.count <= max ? out : nil
    }

    /// Writes `dir/name` whole: a temp file the mod's names never match (it starts with "."), then a rename.
    private static func writeWhole(_ dir: String, _ name: String, _ data: Data) throws {
        let tmp = dir + "/." + name + "." + UUID().uuidString.lowercased() + ".tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure("Couldn't write to the bridge folder (\(String(cString: strerror(errno)))).") }
        var ok = true
        data.withUnsafeBytes { p in
            var at = 0
            while at < p.count {
                let n = write(fd, p.baseAddress! + at, p.count - at)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { ok = false; break }
                at += n
            }
        }
        close(fd)
        guard ok, rename(tmp, dir + "/" + name) == 0 else {
            unlink(tmp)
            throw Failure("Couldn't write to the bridge folder.")
        }
    }

    /// Deletes a file or a link (never what a link points to).
    private static func unlinkFile(_ p: String) {
        var st = stat()
        guard lstat(p, &st) == 0, st.st_mode & S_IFMT != S_IFDIR else { return }
        unlink(p)
    }
}

// MARK: - The Claude app

/// Links into the Claude app. The opener can be swapped out (tests never open the real app).
@MainActor enum ClaudeApp {
    static let bundleId = "com.anthropic.claudefordesktop"
    /// Opens a claude:// link. Tests put a recorder here.
    static var open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    /// Brings the Claude app forward. Tests put a recorder here.
    static var activate: () -> Bool = {
        guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return false }
        let c = NSWorkspace.OpenConfiguration()
        c.activates = true
        NSWorkspace.shared.openApplication(at: u, configuration: c, completionHandler: nil)
        return true
    }
    /// Tests set this; else whether the Claude app is on this Mac.
    static var installedOverride: Bool?
    static var isInstalled: Bool {
        installedOverride ?? (NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil)
    }

    /// Letters, digits and -._~ stay; everything else is %-encoded (so "&", "+", "=" and "#" in a message survive).
    private static let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// claude://code/new?q=<text>&folder=<folder>: the app's new-chat page with the message filled in. It never
    /// sends; the app asks to confirm the folder.
    static func newChatURL(text: String, folder: String) -> URL? {
        guard let q = text.addingPercentEncoding(withAllowedCharacters: plain),
              let f = folder.addingPercentEncoding(withAllowedCharacters: plain) else { return nil }
        return URL(string: "claude://code/new?q=\(q)&folder=\(f)")
    }

    /// claude://claude.ai/epitaxy/local_<id>: that chat in the Claude app (the link the app's own tools use).
    static func chatURL(desktopId d: String) -> URL? {
        guard d.hasPrefix("local_"), d.count <= 120,
              d.dropFirst(6).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), d.count > 6 else { return nil }
        return URL(string: "claude://claude.ai/epitaxy/" + d)
    }

    /// Shows this chat in the Claude app if the app knows it, else just brings the app forward.
    @discardableResult
    static func openChat(_ session: String?) -> Bool {
        if let s = session, let d = ChatIndex.shared.appChatId(s), let u = chatURL(desktopId: d) { return open(u) }
        return activate()
    }
}

// MARK: - Sync with Claude App: turning it on and off

/// Installs the sticky-bridge mod for your user with the claude CLI (a folder marketplace Sticky keeps), and
/// remembers whether sync is on. Only ever runs `claude plugin …`; the CLI changes Claude's own settings.
@MainActor enum ClaudeSync {
    nonisolated static let marketplace = "sticky-local"
    nonisolated static let plugin = "sticky-bridge"
    nonisolated static var pluginId: String { plugin + "@" + marketplace }

    private static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sticky")
    /// Whether sync is on and which mod version was written. Tests point it elsewhere first.
    static var stateURL = supportDir.appendingPathComponent("claude-sync.json")
    /// The folder marketplace: .claude-plugin/marketplace.json and sticky-bridge/. Tests point it elsewhere first.
    static var modDir = supportDir.appendingPathComponent("claude-mod")
    /// Tests: the claude CLI runs with this HOME (never the real one).
    static var home: String?

    struct Outcome {
        var ok: Bool
        var message: String
    }

    private struct State: Codable {
        var on: Bool
        var version: String?
    }

    private static var state: State = {
        guard let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: d) else {
            return State(on: false, version: nil)
        }
        return s
    }()
    private(set) static var isWorking = false

    static var isOn: Bool { state.on }

    private static func save(_ s: State) {
        let was = state.on
        state = s
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: stateURL, options: .atomic) }
        if was != s.on { NotificationCenter.default.post(name: .stickyClaudeSync, object: nil) }
    }

    /// Writes the mod's files, then `claude plugin marketplace add <modDir> --scope user` and
    /// `claude plugin install sticky-bridge@sticky-local --scope user`. Undoes the first if the second fails.
    /// (Both checked on Claude Code 2.1.325 with stdin closed: no prompts. Run again, each still says ok.)
    static func turnOn(_ done: @escaping @MainActor (Outcome) -> Void) {
        guard !isWorking else { return }
        isWorking = true
        let dir = modDir, h = home
        DispatchQueue.global(qos: .userInitiated).async {
            let r: Outcome
            do {
                try writeMod(to: dir)
                try? ClaudeBridge.makeFolders()
                ClaudeBridge.sweep()
                let add = runClaude(["plugin", "marketplace", "add", dir.path, "--scope", "user", "--json"], home: h)
                if !add.ok {
                    r = Outcome(ok: false, message: "Claude Code couldn't add Sticky's marketplace: " + add.message)
                } else {
                    let inst = runClaude(["plugin", "install", pluginId, "--scope", "user", "--json"], home: h)
                    if inst.ok {
                        r = Outcome(ok: true, message: "Sticky's mod is installed. Claude app chats you open from now on take "
                            + "messages from Sticky. Chats already open pick it up within a few seconds.")
                    } else {
                        _ = runClaude(["plugin", "marketplace", "remove", marketplace, "--json"], home: h)
                        r = Outcome(ok: false, message: "Claude Code couldn't install Sticky's mod: " + inst.message)
                    }
                }
            } catch let e {
                r = Outcome(ok: false, message: e.localizedDescription)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    isWorking = false
                    if r.ok { save(State(on: true, version: ClaudeBridgeMod.stamp)) }
                    done(r)
                }
            }
        }
    }

    /// `claude plugin uninstall sticky-bridge@sticky-local --scope user`, `claude plugin marketplace remove
    /// sticky-local`, then deletes the mod's folder (the CLI leaves it). Already gone (`not_installed`,
    /// `not_configured`) counts as done.
    static func turnOff(_ done: @escaping @MainActor (Outcome) -> Void) {
        guard !isWorking else { return }
        isWorking = true
        let dir = modDir, h = home
        DispatchQueue.global(qos: .userInitiated).async {
            let un = runClaude(["plugin", "uninstall", pluginId, "--scope", "user", "--json"], home: h)
            let rm = runClaude(["plugin", "marketplace", "remove", marketplace, "--json"], home: h)
            let unOk = un.ok || un.failureCode == "not_installed"
            let rmOk = rm.ok || rm.failureCode == "not_configured"
            if unOk && rmOk { removeMod(dir) }
            let r = unOk && rmOk
                ? Outcome(ok: true, message: "Sticky's mod is uninstalled. Claude app chats that have it keep it until they restart; "
                    + "Sticky stops sending to them now.")
                : Outcome(ok: false, message: "Claude Code couldn't remove Sticky's mod: " + (unOk ? rm.message : un.message))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    isWorking = false
                    if r.ok { save(State(on: false, version: nil)) }
                    done(r)
                }
            }
        }
    }

    /// At launch: with sync on, makes the bridge folders if they're gone and rewrites the mod's files when this Sticky
    /// embeds others (ClaudeBridgeMod.stamp), then `claude plugin update` (the CLI reads the plugin from the folder
    /// in place, so new chats get the new files either way; the update only refreshes its record). Also sweeps the
    /// bridge folder.
    static func refreshIfNeeded(_ done: (@MainActor (Outcome) -> Void)? = nil) {
        // The mod only acts when the bridge folder is there (Sticky makes it): make sure it is, with sync on.
        let on = isOn
        DispatchQueue.global(qos: .utility).async {
            if on { try? ClaudeBridge.makeFolders() }
            ClaudeBridge.sweep()
        }
        guard on, !isWorking, state.version != ClaudeBridgeMod.stamp else { return }
        isWorking = true
        let dir = modDir, h = home
        DispatchQueue.global(qos: .utility).async {
            var r = Outcome(ok: true, message: "")
            do {
                try writeMod(to: dir)
                let up = runClaude(["plugin", "update", pluginId, "--scope", "user", "--json"], home: h)
                r.message = up.message
            } catch let e {
                r = Outcome(ok: false, message: e.localizedDescription)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    isWorking = false
                    if r.ok { save(State(on: true, version: ClaudeBridgeMod.stamp)) }
                    done?(r)
                }
            }
        }
    }

    // MARK: The mod's folder

    /// modDir/.claude-plugin/marketplace.json plus modDir/sticky-bridge/<the embedded files>, byte for byte as
    /// mods/embed.sh embedded them. The plugin folder is written next to the old one and swapped in, so a Claude
    /// starting meanwhile never reads half of it.
    nonisolated static func writeMod(to dir: URL) throws {
        let fm = FileManager.default
        let root = dir.path
        try? fm.createDirectory(atPath: (root as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try ClaudeBridge.makeDir(root)
        try ClaudeBridge.makeDir(root + "/.claude-plugin")
        try Data(ClaudeBridgeMod.marketplace.utf8).write(to: URL(fileURLWithPath: root + "/.claude-plugin/marketplace.json"),
                                                         options: .atomic)

        let fresh = root + "/." + plugin + "." + UUID().uuidString.lowercased()
        try ClaudeBridge.makeDir(fresh)
        do {
            for f in ClaudeBridgeMod.files {
                let parts = f.path.split(separator: "/").map(String.init)
                guard !f.path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
                    throw ClaudeBridge.Failure("A file of the mod has a bad path: \(f.path)")
                }
                var d = fresh
                for p in parts.dropLast() {
                    d += "/" + p
                    try ClaudeBridge.makeDir(d)
                }
                try Data(f.text.utf8).write(to: URL(fileURLWithPath: fresh + "/" + f.path), options: .atomic)
            }
            let live = root + "/" + plugin
            let old = root + "/." + plugin + ".old." + UUID().uuidString.lowercased()
            var st = stat()
            if lstat(live, &st) == 0 { guard rename(live, old) == 0 else { throw ClaudeBridge.Failure("Couldn't replace the mod's files.") } }
            guard rename(fresh, live) == 0 else { throw ClaudeBridge.Failure("Couldn't write the mod's files.") }
            if lstat(old, &st) == 0 { removeTree(old) }
        } catch let e {
            removeTree(fresh)
            throw e
        }
    }

    nonisolated private static func removeMod(_ dir: URL) {
        var st = stat()
        guard lstat(dir.path, &st) == 0 else { return }
        if st.st_mode & S_IFMT == S_IFLNK { unlink(dir.path); return }  // never into what a link points to
        removeTree(dir.path)
    }

    /// Deletes a folder Sticky made (FileManager deletes a link inside it as a link, not what it points to).
    nonisolated private static func removeTree(_ p: String) {
        try? FileManager.default.removeItem(atPath: p)
    }

    // MARK: Running the claude CLI

    struct CLIResult {
        var ok: Bool
        var message: String
        var failureCode: String?
        var code: Int32
    }

    /// Runs `claude <args>` (never through a shell) with Sticky's environment for claude, stdin closed, for at most
    /// 90 s. ok = exit 0 and the last JSON line says "outcome": "ok".
    nonisolated static func runClaude(_ args: [String], home: String?) -> CLIResult {
        guard let exe = ClaudeProcess.findClaude() else {
            return CLIResult(ok: false, message: "Claude Code isn't installed: no `claude` in ~/.local/bin or your PATH.",
                             failureCode: nil, code: -1)
        }
        var env = ClaudeProcess.environment()
        if let home { env["HOME"] = home }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: home ?? NSHomeDirectory(), isDirectory: true)
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let ended = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in ended.signal() }
        let outData = Collected(), errData = Collected()
        let group = DispatchGroup()
        for (pipe, box) in [(out, outData), (err, errData)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                box.set(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }
        do { try p.run() } catch {
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            return CLIResult(ok: false, message: "Couldn't run claude: \(error.localizedDescription)", failureCode: nil, code: -1)
        }
        if ended.wait(timeout: .now() + 90) == .timedOut {
            p.terminate()
            _ = ended.wait(timeout: .now() + 5)
        }
        _ = group.wait(timeout: .now() + 5)
        let o = String(decoding: outData.get(), as: UTF8.self)
        var json: [String: Any]?
        for l in o.split(separator: "\n").reversed() {
            if let d = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any], d["outcome"] != nil { json = d; break }
        }
        let code = p.isRunning ? -1 : p.terminationStatus
        let tail = String(decoding: errData.get(), as: UTF8.self).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(2).joined(separator: " ")
        let message = (json?["message"] as? String) ?? (tail.isEmpty ? "claude exited with code \(code)." : tail)
        return CLIResult(ok: code == 0 && json?["outcome"] as? String == "ok", message: message,
                         failureCode: json?["failureCode"] as? String, code: code)
    }
}

/// Bytes read on another thread.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var d = Data()
    func set(_ x: Data) { lock.lock(); d = x; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return d }
}
