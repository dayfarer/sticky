// Reads one Claude Code chat file (.jsonl) into chat items for the branch you see, a little at a time.
//
// Only the rows that matter are parsed (by their first bytes). Each row is kept as a small summary,
// never as raw JSON, so even a 100 MB chat stays light. Images are re-read from the file on demand.
import Foundation

// MARK: - Items

/// A display item on the chat page. Plain values only, so it can be compared and sent to the page.
struct ChatItem: Equatable {
    var id: String            // stable key: the row uuid, or the tool_use id for tools
    var kind: String          // user | assistant | thinking | tool | chip | output | divider | summary | notice | error | interrupted
    var text: String = ""     // markdown for assistant / thinking / summary; plain text for the rest
    var images: [String] = [] // image keys (user images); fetch with ChatTranscript.image(_:)
    var time: Double? = nil   // unix seconds
    var meta: String? = nil   // small grey label (e.g. "auto" on a compaction divider, the model on an error)
    var tool: ChatTool? = nil

    /// The page's Item dictionary. Leaves out empty and nil fields.
    var js: [String: Any] {
        var d: [String: Any] = ["id": id, "kind": kind]
        if !text.isEmpty { d["text"] = text }
        if !images.isEmpty { d["images"] = images }
        if let time { d["time"] = time }
        if let meta { d["meta"] = meta }
        if let t = tool {
            var o: [String: Any] = ["name": t.name, "title": t.title, "input": t.input, "isError": t.isError]
            if let r = t.result { o["result"] = r }
            if !t.images.isEmpty { o["images"] = t.images }
            if let df = t.diff { o["diff"] = df }
            d["tool"] = o
        }
        return d
    }
}

struct ChatTool: Equatable {
    var name: String          // raw tool name ("Bash", "mcp__notion__search")
    var title: String         // one line for the collapsed row: "Ran `git status`", "Read main.swift"
    var input: String         // what was asked: the command for Bash, pretty JSON otherwise
    var result: String?       // nil = no result yet
    var isError: Bool = false
    var images: [String] = [] // image keys inside the tool result
    var diff: String? = nil   // "+"/"-"/" " lines for Edit / MultiEdit / Write
}

// MARK: - Transcript

private extension String {
    /// Without leading and trailing whitespace. Skips the work when there is none (the usual case).
    var chatTrimmed: String {
        guard let f = unicodeScalars.first, let l = unicodeScalars.last else { return self }
        if !f.properties.isWhitespace && !l.properties.isWhitespace { return self }
        return trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nothing but whitespace (stops at the first other character).
    var chatBlank: Bool {
        !unicodeScalars.contains { !$0.properties.isWhitespace }
    }
}

/// One chat's .jsonl. Not thread-safe: use it from one background queue at a time.
final class ChatTranscript: @unchecked Sendable {
    let path: String
    private(set) var items: [ChatItem] = []     // the active branch, oldest first
    private(set) var cwd: String?               // where to continue the chat
    private(set) var title: String?             // newest custom title, else AI title, else agent name, else summary
    private(set) var firstPrompt: String?       // first thing you typed, one line
    private(set) var lastModel: String?         // model of the last real reply
    private(set) var lastEffort: String?        // effort of the last reply that has one
    private(set) var gitBranch: String?         // last branch that isn't "HEAD"
    private(set) var blockCounts: [String: Int] = [:] // reply id → rows of it on file

    /// One transcript row, boiled down to what the branch walk and the page need.
    private struct Row {
        var uuid: String
        var parent: String?        // last write
        var firstParent: String?   // first write (used before a compaction)
        var logical: String?       // a compaction's link back into older history
        var pos: Int               // file order of the last write
        var msg: String?           // reply id (assistant rows)
        var boundary = false       // compaction boundary
        var apiError = false       // shown only when it ends the branch
        var items: [ChatItem] = [] // tools here have no result yet
    }

    private struct Result {
        var text: String
        var isError: Bool
        var images: [String]
        var diff: String?
    }

    private var rows: [Row] = []
    private var index: [String: Int] = [:]   // uuid → rows index
    private var byMsg: [String: [Int]] = [:] // reply id → rows indexes
    private var results: [String: Result] = [:] // tool_use id → result
    private var leaf = -1                    // the row written last
    private var pos = 0
    private var replies = 0                  // changes whenever blockCounts does

    private var done: UInt64 = 0             // bytes read, always just after a "\n"
    private var inode: UInt64 = 0
    private let folder: String               // the project folder's name (an encoded cwd)

    private var customTitle: String?, aiTitle: String?, agentName: String?, summaryTitle: String?
    private var relocated: String?, firstCwd: String?, matchCwd: String?
    private var lastCwd: String?, lastCwdMatches = false

    init(path: String) {
        self.path = path
        folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    /// Reads what was added since the last call (the whole file the first time). Returns true if items or
    /// metadata changed. A half-written last line is left for next time. A shrunk or replaced file starts over.
    func update() -> Bool {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return false }
        let size = UInt64(max(0, st.st_size))
        let ino = UInt64(st.st_ino)

        var restarted = false
        if ino != inode || size < done || !endsLine(fd, at: done) {
            restarted = done > 0 || !rows.isEmpty
            reset()
            inode = ino
        }
        guard size > done else { return restarted }

        // Read in chunks of up to 8 MB (growing only for a longer line), so a big chat never sits in memory whole.
        let before = snapshot()
        var added = false
        var cap = max(64 << 10, Int(min(size - done, 8 << 20)))
        var buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
        defer { buf.deallocate() }
        var have = 0          // bytes in buf
        var base = done       // file offset of buf[0]
        var at = done         // next byte to read
        while at < size {
            if have == cap {
                let bigger = UnsafeMutableRawPointer.allocate(byteCount: cap * 2, alignment: 16)
                bigger.copyMemory(from: buf, byteCount: have)
                buf.deallocate()
                buf = bigger
                cap *= 2
            }
            let n = pread(fd, buf + have, min(cap - have, Int(size - at)), off_t(at))
            if n <= 0 { break }
            have += n
            at += UInt64(n)
            let p = buf.assumingMemoryBound(to: UInt8.self)
            var start = 0
            while start < have, let nl = memchr(p + start, 0x0A, have - start) {
                let end = UnsafeRawPointer(p).distance(to: UnsafeRawPointer(nl))
                // A pool per line, so parsed rows (some are megabytes of image data) are freed right away.
                if autoreleasepool(invoking: { line(p + start, end - start, offset: base + UInt64(start)) }) { added = true }
                start = end + 1
            }
            if start > 0 {
                if start < have { memmove(buf, buf + start, have - start) }
                have -= start
                base += UInt64(start)
            }
        }
        done = base

        if added || restarted {
            let fresh = build()
            if restarted || fresh != items { items = fresh; return true }
        }
        return restarted || snapshot() != before
    }

    /// A `data:` URL for an image key from `items` (re-reads that one row from the file), or nil.
    func image(_ key: String) -> String? {
        let parts = key.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ $0 >= 0 }),
              let data = readLine(at: UInt64(parts[0])),
              let d = Self.parse(data) else { return nil }
        let content = ((d["message"] as? [String: Any])?["content"] ?? (d["attachment"] as? [String: Any])?["prompt"]) as? [Any]
        guard let list = content, parts[1] < list.count, var b = list[parts[1]] as? [String: Any] else { return nil }
        if parts.count == 3 {
            guard let sub = b["content"] as? [Any], parts[2] < sub.count, let s = sub[parts[2]] as? [String: Any] else { return nil }
            b = s
        }
        guard b["type"] as? String == "image", let src = b["source"] as? [String: Any],
              src["type"] as? String == "base64", let mt = src["media_type"] as? String,
              ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mt),
              let b64 = src["data"] as? String, !b64.isEmpty else { return nil }
        return "data:\(mt);base64,\(b64)"
    }

    // MARK: Reading the file

    private func reset() {
        rows = []; index = [:]; byMsg = [:]; results = [:]; leaf = -1; pos = 0; replies = 0; done = 0
        items = []; blockCounts = [:]
        customTitle = nil; aiTitle = nil; agentName = nil; summaryTitle = nil
        relocated = nil; firstCwd = nil; matchCwd = nil; lastCwd = nil; lastCwdMatches = false
        cwd = nil; title = nil; firstPrompt = nil; lastModel = nil; lastEffort = nil; gitBranch = nil
    }

    private struct Meta: Equatable {
        var cwd, title, firstPrompt, lastModel, lastEffort, gitBranch: String?
        var replies: Int
    }

    private func snapshot() -> Meta {
        Meta(cwd: cwd, title: title, firstPrompt: firstPrompt, lastModel: lastModel, lastEffort: lastEffort,
             gitBranch: gitBranch, replies: replies)
    }

    /// The byte just before `at` is a newline (so the part we read before is still there).
    private func endsLine(_ fd: Int32, at: UInt64) -> Bool {
        guard at > 0 else { return true }
        var b: UInt8 = 0
        return pread(fd, &b, 1, off_t(at - 1)) == 1 && b == 0x0A
    }

    private static let transcriptPrefix = Array(#"{"parentUuid":"#.utf8)
    private static let metaPrefixes: [[UInt8]] = ["custom-title", "ai-title", "agent-name", "summary", "relocated"]
        .map { Array(#"{"type":"\#($0)""#.utf8) }

    private static func has(_ p: UnsafePointer<UInt8>, _ n: Int, _ prefix: [UInt8]) -> Bool {
        n >= prefix.count && memcmp(p, prefix, prefix.count) == 0
    }

    /// Handles one complete line. Returns true if it added or changed a transcript row.
    private func line(_ p: UnsafePointer<UInt8>, _ n: Int, offset: UInt64) -> Bool {
        if Self.has(p, n, Self.transcriptPrefix) {
            guard let d = Self.parse(Data(bytes: p, count: n)) else { return false }
            return transcriptRow(d, offset: offset)
        }
        guard Self.metaPrefixes.contains(where: { Self.has(p, n, $0) }),
              let d = Self.parse(Data(bytes: p, count: n)) else { return false }
        func s(_ k: String) -> String? {
            guard let v = d[k] as? String else { return nil }
            let t = v.chatTrimmed
            return t.isEmpty ? nil : t
        }
        switch d["type"] as? String {
        case "custom-title": if let v = s("customTitle") { customTitle = v }
        case "ai-title": if let v = s("aiTitle") { aiTitle = v }
        case "agent-name": if let v = s("agentName") { agentName = v }
        case "summary": if let v = s("summary") { summaryTitle = v }
        case "relocated": if let v = s("relocatedCwd") { relocated = v }
        default: return false
        }
        title = customTitle ?? aiTitle ?? agentName ?? summaryTitle
        cwd = relocated ?? matchCwd ?? firstCwd
        return false
    }

    /// One JSON row as a dictionary. JavaScript can write a lone half of an emoji as `\ud83d` when it cuts a
    /// string; Foundation rejects the whole row for that, which would cut the chat's history off at that row.
    /// So a row that fails gets those escapes replaced with U+FFFD (and bad UTF-8 repaired) and is tried again.
    private static func parse(_ data: Data) -> [String: Any]? {
        if let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return d }
        var b = [UInt8](data)
        func hex(_ i: Int) -> Int? {
            guard i + 4 <= b.count else { return nil }
            var v = 0
            for k in i..<(i + 4) {
                let c = b[k]
                switch c {
                case 0x30...0x39: v = v * 16 + Int(c - 0x30)
                case 0x41...0x46: v = v * 16 + Int(c - 0x37)
                case 0x61...0x66: v = v * 16 + Int(c - 0x57)
                default: return nil
                }
            }
            return v
        }
        var i = 0
        while i + 1 < b.count {
            guard b[i] == 0x5C else { i += 1; continue }                 // "\"
            guard b[i + 1] == 0x75, let v = hex(i + 2) else { i += 2; continue }   // not "\uXXXX"
            if (0xD800...0xDBFF).contains(v), i + 12 <= b.count, b[i + 6] == 0x5C, b[i + 7] == 0x75,
               let w = hex(i + 8), (0xDC00...0xDFFF).contains(w) {
                i += 12                                                   // a proper pair
                continue
            }
            if (0xD800...0xDFFF).contains(v) { b.replaceSubrange((i + 2)..<(i + 6), with: Array("fffd".utf8)) }
            i += 6
        }
        let fixed = Data(String(decoding: b, as: UTF8.self).utf8)
        return (try? JSONSerialization.jsonObject(with: fixed)) as? [String: Any]
    }

    private func readLine(at off: UInt64) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: off)) != nil else { return nil }
        var out = Data()
        while out.count < 64 << 20 {
            guard let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            if let nl = chunk.firstIndex(of: 0x0A) {
                out.append(chunk[chunk.startIndex..<nl])
                return out
            }
            out.append(chunk)
        }
        return out.isEmpty ? nil : out
    }

    // MARK: Rows

    private func transcriptRow(_ d: [String: Any], offset: UInt64) -> Bool {
        guard let uuid = d["uuid"] as? String, let type = d["type"] as? String,
              d["isSidechain"] as? Bool != true else { return false }
        let time = (d["timestamp"] as? String).flatMap(Self.parseTime)
        if let c = d["cwd"] as? String {
            if c != lastCwd { lastCwd = c; lastCwdMatches = Self.encode(c) == folder }
            if firstCwd == nil { firstCwd = c }
            if lastCwdMatches { matchCwd = c }
            cwd = relocated ?? matchCwd ?? firstCwd
        }
        if let g = d["gitBranch"] as? String, g != "HEAD", !g.isEmpty { gitBranch = g }

        var row = Row(uuid: uuid, parent: d["parentUuid"] as? String, firstParent: nil, pos: pos)
        pos += 1
        switch type {
        case "user":
            row.items = userItems(d, uuid: uuid, time: time, offset: offset)
            if firstPrompt == nil, d["isCompactSummary"] as? Bool != true,
               let u = row.items.first(where: { $0.kind == "user" }), !u.text.isEmpty {
                firstPrompt = Self.oneLine(u.text, 200)
            }
        case "assistant":
            let m = d["message"] as? [String: Any]
            row.msg = m?["id"] as? String
            if let model = m?["model"] as? String, model != "<synthetic>", !model.isEmpty { lastModel = model }
            if let e = d["effort"] as? String, !e.isEmpty { lastEffort = e }
            row.items = assistantItems(d, m, uuid: uuid, time: time)
        case "system":
            row.boundary = d["subtype"] as? String == "compact_boundary"
            row.logical = d["logicalParentUuid"] as? String
            row.apiError = d["subtype"] as? String == "api_error"
            row.items = systemItems(d, uuid: uuid, time: time)
        case "attachment":
            row.items = attachmentItems(d, uuid: uuid, time: time, offset: offset)
        default:
            pos -= 1
            return false
        }

        if let k = index[uuid] {
            // A copy written again: the newest data wins, the first parent is kept.
            row.firstParent = rows[k].firstParent
            if let old = rows[k].msg, old != row.msg {
                byMsg[old]?.removeAll { $0 == k }
                blockCounts[old] = byMsg[old].flatMap { $0.isEmpty ? nil : $0.count }
                replies += 1
            }
            if let m = row.msg, rows[k].msg != m { byMsg[m, default: []].append(k); blockCounts[m] = byMsg[m]?.count; replies += 1 }
            rows[k] = row
            leaf = k
        } else {
            row.firstParent = row.parent
            let k = rows.count
            rows.append(row)
            index[uuid] = k
            if let m = row.msg { byMsg[m, default: []].append(k); blockCounts[m, default: 0] += 1; replies += 1 }
            leaf = k
        }
        return true
    }

    // MARK: Active branch

    /// Walks back from the last row written, crossing compactions, then shows each reply whole, in file order.
    private func build() -> [ChatItem] {
        guard leaf >= 0 else { return [] }
        var seen = [Bool](repeating: false, count: rows.count)
        var chain: [Int] = []
        chain.reserveCapacity(rows.count)
        var useFirst = false
        var u: Int? = leaf
        var steps = 0
        while let i = u, steps < 2 * rows.count + 10 {
            steps += 1
            if seen[i] { u = rows[i].firstParent.flatMap { index[$0] }; continue }
            seen[i] = true
            chain.append(i)
            let r = rows[i]
            var p = useFirst ? r.firstParent : r.parent
            if p == nil, r.boundary, let l = r.logical { p = l; useFirst = true }
            u = p.flatMap { index[$0] }
        }
        chain.reverse()

        var out: [ChatItem] = []
        out.reserveCapacity(chain.count)
        var ids = Set<String>()
        ids.reserveCapacity(chain.count)
        var doneMsg = Set<String>()
        var lastError: ChatItem?
        func emit(_ r: Row) {
            if r.apiError { if let e = r.items.first { lastError = e }; return }
            for var it in r.items {
                lastError = nil
                if var t = it.tool, let res = results[it.id] {
                    t.result = res.text
                    t.isError = res.isError
                    t.images = res.images
                    if let df = res.diff { t.diff = df }
                    it.tool = t
                }
                if !ids.insert(it.id).inserted {
                    var n = 2
                    while !ids.insert("\(it.id)~\(n)").inserted { n += 1 }
                    it.id = "\(it.id)~\(n)"
                }
                out.append(it)
            }
        }
        for i in chain {
            let r = rows[i]
            if let m = r.msg {
                guard doneMsg.insert(m).inserted else { continue }
                let turn = byMsg[m] ?? [i]
                if turn.count == 1 { emit(rows[turn[0]]); continue }
                for j in turn.sorted(by: { rows[$0].pos < rows[$1].pos }) { emit(rows[j]) }
            } else {
                emit(r)
            }
        }
        if let e = lastError { out.append(e) }
        return out
    }

    // MARK: User rows

    private func userItems(_ d: [String: Any], uuid: String, time: Double?, offset: UInt64) -> [ChatItem] {
        let content = (d["message"] as? [String: Any])?["content"]
        if d["isCompactSummary"] as? Bool == true {
            let text = (content as? String) ?? Self.blockTexts(content).joined(separator: "\n\n")
            return [ChatItem(id: uuid, kind: "summary", text: text.chatTrimmed, time: time)]
        }
        if d["isMeta"] as? Bool == true { return [] }
        if let list = content as? [Any] {
            var hasResult = false
            for (bi, any) in list.enumerated() {
                guard let b = any as? [String: Any], b["type"] as? String == "tool_result" else { continue }
                hasResult = true
                record(b, extra: d["toolUseResult"], offset: offset, block: bi)
            }
            if hasResult { return [] }
        }
        let (text, images) = Self.prompt(content, offset: offset)
        return promptItems(text, images, origin: d["origin"], id: uuid, time: time)
    }

    /// The words and image keys of a prompt (a string, or text and image blocks), without system reminders.
    private static func prompt(_ content: Any?, offset: UInt64) -> (String, [String]) {
        if let s = content as? String { return (stripReminders(s).chatTrimmed, []) }
        guard let list = content as? [Any] else { return ("", []) }
        var texts: [String] = []
        var images: [String] = []
        for (bi, any) in list.enumerated() {
            guard let b = any as? [String: Any] else { continue }
            switch b["type"] as? String {
            case "text":
                guard let t = b["text"] as? String else { continue }
                let s = stripReminders(t).chatTrimmed
                if !s.isEmpty { texts.append(s) }
            case "image":
                images.append("\(offset).\(bi)")
            default: break
            }
        }
        return (texts.joined(separator: "\n\n"), images)
    }

    private static let appWrappers: [(tag: String, label: String)] = [
        ("artifact-view-context", "Viewing an artifact"),
        ("launch-selected-element", "Selected an element"),
        ("create-pr-command", "Create a pull request"),
    ]

    /// What a prompt shows as: your message, a chip for commands and notifications, or a terminal block.
    private func promptItems(_ raw: String, _ images: [String], origin: Any?, id: String, time: Double?) -> [ChatItem] {
        var t = raw
        func item(_ kind: String, _ text: String, meta: String? = nil) -> [ChatItem] {
            [ChatItem(id: id, kind: kind, text: text, images: kind == "user" ? images : [], time: time, meta: meta)]
        }
        if t == "[Request interrupted by user]" || t == "[Request interrupted by user for tool use]" {
            return item("interrupted", "Interrupted")
        }
        let o = origin as? [String: Any]
        let from = o?["kind"] as? String
        if from == "peer" {
            return item("chip", "Message from another session", meta: (o?["name"] as? String).map { Self.oneLine($0, 60) })
        }
        if t.hasPrefix("<scheduled-task") {
            let name = Self.attribute("name", in: t).map { Self.oneLine($0, 80) }
            return item("chip", name.map { "Scheduled task: \($0)" } ?? "Scheduled task")
        }
        if t.hasPrefix("<task-notification>") || from == "task-notification" { return item("chip", Self.taskSummary(t)) }
        if t.hasPrefix("<command-name>") || t.hasPrefix("<command-message>") {
            var name = Self.inner("command-name", in: t) ?? Self.inner("command-message", in: t) ?? ""
            name = name.chatTrimmed
            if !name.hasPrefix("/") { name = "/" + name }
            let args = Self.oneLine(Self.inner("command-args", in: t) ?? "", 200)
            return item("chip", args.isEmpty ? name : "\(name) \(args)")
        }
        if t.hasPrefix("<local-command-stdout>") || t.hasPrefix("<local-command-stderr>") {
            let out = [Self.inner("local-command-stdout", in: t), Self.inner("local-command-stderr", in: t)]
                .compactMap { $0.map(Self.plainOutput) }.filter { !$0.isEmpty }.joined(separator: "\n")
            return out.isEmpty ? [] : item("output", out)
        }
        if t.hasPrefix("<bash-input>") || t.hasPrefix("<bash-stdout>") || t.hasPrefix("<bash-stderr>") {
            var parts: [String] = []
            if let cmd = Self.inner("bash-input", in: t) { parts.append("! " + cmd.chatTrimmed) }
            for tag in ["bash-stdout", "bash-stderr"] {
                if let s = Self.inner(tag, in: t).map(Self.plainOutput), !s.isEmpty { parts.append(s) }
            }
            return parts.isEmpty ? [] : item("output", parts.joined(separator: "\n"))
        }
        if t.hasPrefix("<side-sessions-event>") { return item("chip", "Side session update") }
        if t.hasPrefix("<artifact-content-authored-by-others>") { return item("chip", "Artifact content from others") }
        // App context can come stacked (several selected elements), so drop every wrapper in front.
        var label: String?
        while let w = Self.appWrappers.first(where: { t.hasPrefix("<" + $0.tag) }) {
            let first = label ?? w.label
            label = first
            guard let r = t.range(of: "</\(w.tag)>") else { return item("chip", first) }
            t = String(t[r.upperBound...]).chatTrimmed
        }
        if let label, t.isEmpty && images.isEmpty { return item("chip", label) }
        if Self.find("<pasted_content", in: t) { t = Self.unwrapPasted(t) }
        if t.isEmpty && images.isEmpty { return [] }
        return item("user", t)
    }

    /// Saves a tool's result under its tool_use id (the newest write wins).
    private func record(_ b: [String: Any], extra: Any?, offset: UInt64, block: Int) {
        guard let id = b["tool_use_id"] as? String else { return }
        var text = ""
        var images: [String] = []
        if let s = b["content"] as? String {
            text = s
        } else if let list = b["content"] as? [Any] {
            var texts: [String] = []
            for (si, any) in list.enumerated() {
                guard let x = any as? [String: Any] else { continue }
                switch x["type"] as? String {
                case "text": if let s = x["text"] as? String { texts.append(s) }
                case "image": images.append("\(offset).\(block).\(si)")
                case "tool_reference": if let n = x["tool_name"] as? String { texts.append("Loaded \(n)") }
                case "document": texts.append("[document]")
                default: break
                }
            }
            text = texts.joined(separator: "\n")
        }
        text = Self.clip(text, 30_000)
        if Self.find("<system-reminder>", in: text) { text = Self.stripReminders(text) }
        text = text.chatTrimmed
        var diff: String?
        if let r = extra as? [String: Any], let hunks = r["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
            diff = Self.patchText(hunks)
        }
        results[id] = Result(text: text, isError: b["is_error"] as? Bool ?? false, images: images, diff: diff)
    }

    // MARK: Assistant, system and attachment rows

    private func assistantItems(_ d: [String: Any], _ m: [String: Any]?, uuid: String, time: Double?) -> [ChatItem] {
        let content = m?["content"]
        if d["isApiErrorMessage"] as? Bool == true {
            let text = (content as? String) ?? Self.blockTexts(content).joined(separator: "\n\n")
            return [ChatItem(id: uuid, kind: "error", text: text.chatTrimmed,
                             time: time, meta: d["error"] as? String)]
        }
        if let s = content as? String {
            let t = s.chatTrimmed
            return t.isEmpty ? [] : [ChatItem(id: uuid, kind: "assistant", text: t, time: time)]
        }
        guard let list = content as? [Any] else { return [] }
        var out: [ChatItem] = []
        for (bi, any) in list.enumerated() {
            guard let b = any as? [String: Any] else { continue }
            let key = bi == 0 ? uuid : "\(uuid).\(bi)"
            switch b["type"] as? String {
            case "text":
                // Markdown ignores outer whitespace, so it isn't trimmed here (that would copy every reply).
                guard let t = b["text"] as? String, !t.chatBlank else { continue }
                out.append(ChatItem(id: key, kind: "assistant", text: t, time: time))
            case "thinking":
                guard let t = b["thinking"] as? String, !t.chatBlank else { continue }
                let secs = (d["thinkingDurationMs"] as? NSNumber).map { "\(max(1, Int(($0.doubleValue / 1000).rounded())))s" }
                out.append(ChatItem(id: key, kind: "thinking", text: t, time: time, meta: secs))
            case "tool_use":
                guard let id = b["id"] as? String, let name = b["name"] as? String else { continue }
                out.append(ChatItem(id: id, kind: "tool", time: time, tool: Self.tool(name, b["input"])))
            default: break
            }
        }
        return out
    }

    private func systemItems(_ d: [String: Any], uuid: String, time: Double?) -> [ChatItem] {
        let content = (d["content"] as? String)?.chatTrimmed ?? ""
        func item(_ kind: String, _ text: String, meta: String? = nil) -> [ChatItem] {
            [ChatItem(id: uuid, kind: kind, text: text, time: time, meta: meta)]
        }
        switch d["subtype"] as? String {
        case "compact_boundary":
            return item("divider", "Conversation compacted", meta: (d["compactMetadata"] as? [String: Any])?["trigger"] as? String)
        case "api_error":
            let e = d["error"] as? [String: Any]
            let msg = (e?["formatted"] as? String) ?? (e?["message"] as? String) ?? (d["error"] as? String) ?? "API error"
            var meta: String?
            if let a = d["retryAttempt"] as? NSNumber, let m = d["maxRetries"] as? NSNumber { meta = "attempt \(a.intValue) of \(m.intValue)" }
            return item("error", Self.oneLine(msg, 500), meta: meta)
        case "model_refusal_no_fallback":
            let text = content.isEmpty ? ((d["apiRefusalExplanation"] as? String) ?? "The model declined to answer.") : content
            return item("error", text, meta: d["originalModel"] as? String)
        case "informational":
            return content.isEmpty ? [] : item("notice", content)
        case "local_command":
            let out = [Self.inner("local-command-stdout", in: content), Self.inner("local-command-stderr", in: content)]
                .compactMap { $0.map(Self.plainOutput) }.filter { !$0.isEmpty }.joined(separator: "\n")
            let text = out.isEmpty && !content.hasPrefix("<") ? Self.plainOutput(content) : out
            return text.isEmpty ? [] : item("output", text)
        default:
            return []
        }
    }

    private func attachmentItems(_ d: [String: Any], uuid: String, time: Double?, offset: UInt64) -> [ChatItem] {
        guard let a = d["attachment"] as? [String: Any], a["type"] as? String == "queued_command" else { return [] }
        switch a["commandMode"] as? String {
        case "prompt":
            let (text, images) = Self.prompt(a["prompt"], offset: offset)
            return promptItems(text, images, origin: a["origin"], id: uuid, time: time)
        case "task-notification":
            let (text, _) = Self.prompt(a["prompt"], offset: offset)
            return [ChatItem(id: uuid, kind: "chip", text: Self.taskSummary(text), time: time)]
        default:
            return []
        }
    }

    // MARK: Tools

    private static func tool(_ name: String, _ raw: Any?) -> ChatTool {
        let input = raw as? [String: Any] ?? [:]
        let text: String
        if name == "Bash", let c = input["command"] as? String {
            text = clip(c, 20_000)
        } else {
            text = inputText(raw).map { clip($0, 20_000) } ?? ""
        }
        var diff: String?
        switch name {
        case "Edit":
            if let o = input["old_string"] as? String, let n = input["new_string"] as? String { diff = swapLines(o, n) }
        case "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]] ?? []).compactMap { e -> String? in
                guard let o = e["old_string"] as? String, let n = e["new_string"] as? String else { return nil }
                return swapLines(o, n)
            }
            if !edits.isEmpty { diff = clip(edits.joined(separator: "\n"), 30_000) }
        case "Write":
            if let c = input["content"] as? String {
                diff = prefixLines(c, "+", max: 30_000)
            }
        default: break
        }
        return ChatTool(name: name, title: title(name, input), input: text, result: nil, diff: diff)
    }

    /// A tool's input to read: pretty JSON, except that when a field holds text over several lines (an agent's
    /// prompt, a plan, a script) every field is shown as "name:" and its value, the text as written, not as one
    /// line of "\n" escapes. nil if it isn't JSON.
    static func inputText(_ raw: Any?) -> String? {
        func json(_ v: Any) -> String? {
            guard JSONSerialization.isValidJSONObject(v),
                  let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            else { return nil }
            return String(decoding: d, as: UTF8.self)
        }
        guard let raw else { return nil }
        guard let o = raw as? [String: Any], o.values.contains(where: { ($0 as? String)?.contains("\n") == true }) else {
            return json(raw)
        }
        var out: [String] = []
        for k in o.keys.sorted() {
            switch o[k] {
            case let s as String:
                out.append(s.contains("\n") ? "\(k):\n\(s.trimmingCharacters(in: .newlines))\n" : "\(k): \(s)")
            case let n as NSNumber:
                out.append("\(k): " + (CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue))
            case is NSNull, nil:
                out.append("\(k): null")
            case let v?:
                out.append("\(k): " + (json(v) ?? "\(v)"))
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private static func title(_ name: String, _ input: [String: Any]) -> String {
        func s(_ k: String) -> String? {
            guard let v = input[k] as? String else { return nil }
            let t = v.chatTrimmed
            return t.isEmpty ? nil : t
        }
        func file(_ k: String) -> String { s(k).map { ($0 as NSString).lastPathComponent } ?? "a file" }
        switch name {
        case "Bash":
            if let d = s("description") { return oneLine(d, 100) }
            let first = firstLine(s("command") ?? "")
            return "Ran `\(oneLine(first, 80))`"
        case "Read": return "Read \(file("file_path"))"
        case "Edit", "MultiEdit": return "Edited \(file("file_path"))"
        case "Write": return "Wrote \(file("file_path"))"
        case "NotebookEdit": return "Edited \(file("notebook_path"))"
        case "Grep", "Glob": return "Searched `\(oneLine(s("pattern") ?? "", 80))`"
        case "WebFetch":
            let u = s("url") ?? ""
            return "Fetched \(URL(string: u)?.host ?? oneLine(u, 80))"
        case "WebSearch": return "Searched the web for “\(oneLine(s("query") ?? "", 80))”"
        case "Agent", "Task": return s("description").map { "Agent: \(oneLine($0, 80))" } ?? "Agent"
        case "TodoWrite": return "Updated the to-do list"
        case "Skill": return "Used the \(oneLine(s("skill") ?? "", 60)) skill"
        case "AskUserQuestion":
            let q = ((input["questions"] as? [[String: Any]])?.first?["question"] as? String).map { oneLine($0, 80) }
            return q.map { "Asked: \($0)" } ?? "Asked a question"
        default: break
        }
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst(5).components(separatedBy: "__")
            let server = parts.first.map { $0.replacingOccurrences(of: "_", with: " ") } ?? ""
            let tool = parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " ")
            if !server.isEmpty, !tool.isEmpty { return "\(server): \(tool)" }
        }
        let keys = ["description", "query", "command", "file_path", "path", "url", "pattern", "prompt", "name",
                    "title", "skill", "subject", "task_id"]
        let pick = keys.lazy.compactMap { s($0) }.first
            ?? input.keys.sorted().lazy.compactMap { k in s(k).flatMap { $0.count <= 80 ? $0 : nil } }.first
        return pick.map { "\(name): \(oneLine($0, 60))" } ?? name
    }

    /// Old lines as "-", new lines as "+".
    private static func swapLines(_ old: String, _ new: String) -> String {
        let o = old.isEmpty ? [] : [prefixLines(old, "-", max: 15_000)]
        let n = new.isEmpty ? [] : [prefixLines(new, "+", max: 15_000)]
        return (o + n).joined(separator: "\n")
    }

    /// A `structuredPatch` (hunks of "+"/"-"/" " lines) as unified-diff text.
    private static func patchText(_ hunks: [[String: Any]]) -> String {
        var out: [String] = []
        var size = 0
        for h in hunks {
            let n = { (k: String) in (h[k] as? NSNumber)?.intValue ?? 0 }
            let head = "@@ -\(n("oldStart")),\(n("oldLines")) +\(n("newStart")),\(n("newLines")) @@"
            out.append(head); size += head.utf16.count + 1
            for case let l as String in h["lines"] as? [Any] ?? [] {
                out.append(l); size += l.utf16.count + 1
                if size > 30_000 { break }
            }
            if size > 30_000 { break }
        }
        return clip(out.joined(separator: "\n"), 30_000)
    }

    // MARK: Text helpers

    private static func blockTexts(_ content: Any?) -> [String] {
        (content as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil } }
    }

    /// Removes `<system-reminder>…</system-reminder>` spans (an unclosed one runs to the end).
    private static func stripReminders(_ s: String) -> String {
        guard find("<system-reminder>", in: s) else { return s }
        var out = ""
        var rest = s[...]
        while let a = rest.range(of: "<system-reminder>") {
            out += rest[..<a.lowerBound]
            guard let b = rest.range(of: "</system-reminder>", range: a.upperBound..<rest.endIndex) else { return out }
            rest = rest[b.upperBound...]
        }
        out += rest
        return out
    }

    /// The text between `<tag…>` and `</tag>` (to the end if unclosed), or nil if the tag isn't there.
    private static func inner(_ tag: String, in s: String) -> String? {
        guard let a = s.range(of: "<" + tag), let gt = s[a.upperBound...].firstIndex(of: ">") else { return nil }
        let next = s[a.upperBound]
        guard next == ">" || next == " " else { return nil }
        let from = s.index(after: gt)
        let to = s.range(of: "</\(tag)>", range: from..<s.endIndex)?.lowerBound ?? s.endIndex
        return String(s[from..<to])
    }

    private static func attribute(_ name: String, in s: String) -> String? {
        guard let gt = s.firstIndex(of: ">") else { return nil }
        let head = s[..<gt]
        guard let a = head.range(of: name + "=\"") else { return nil }
        let rest = head[a.upperBound...]
        guard let q = rest.firstIndex(of: "\"") else { return nil }
        let v = String(rest[..<q])
        return v.isEmpty ? nil : v
    }

    /// A background task's one-line summary.
    private static func taskSummary(_ s: String) -> String {
        if let v = inner("summary", in: s).map({ oneLine($0, 120) }), !v.isEmpty { return v }
        if let v = inner("status", in: s).map({ oneLine($0, 40) }), !v.isEmpty { return "Background task \(v)" }
        return "Background task update"
    }

    /// Drops `<pasted_content …>` and `</pasted_content>` tags and keeps the pasted text.
    private static func unwrapPasted(_ s: String) -> String {
        var out = ""
        var rest = s[...]
        while let a = rest.range(of: "<pasted_content") {
            out += rest[..<a.lowerBound]
            guard let gt = rest[a.upperBound...].firstIndex(of: ">") else { rest = rest[a.lowerBound...]; break }
            rest = rest[rest.index(after: gt)...]
        }
        out += rest
        return out.replacingOccurrences(of: "</pasted_content>", with: "").chatTrimmed
    }

    /// Terminal output without color codes, trimmed.
    private static func plainOutput(_ s: String) -> String {
        var t = s
        if t.contains("\u{1B}") {
            t = t.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
        }
        return clip(t, 30_000).chatTrimmed
    }

    /// The first `max` characters with `mark` in front of every line (one Foundation call, no split).
    private static func prefixLines(_ s: String, _ mark: String, max: Int) -> String {
        let (head, more) = cut(s, max)
        let t = mark + (head as NSString).replacingOccurrences(of: "\n", with: "\n" + mark)
        return more > 0 ? t + "\n… \(more) more characters" : t
    }

    private static func firstLine(_ s: String) -> String {
        let ns = s as NSString
        let r = ns.range(of: "\n")
        return r.location == NSNotFound ? s : ns.substring(to: r.location)
    }

    /// One line, at most `max` characters (with "…"). Runs of spaces and newlines become one space.
    private static func oneLine(_ s: String, _ max: Int) -> String {
        var out = String.UnicodeScalarView()
        var space = false, n = 0
        for c in s.unicodeScalars {
            if c.properties.isWhitespace { space = !out.isEmpty; continue }
            if space { out.append(" "); n += 1; space = false }
            out.append(c); n += 1
            if n > max { break }
        }
        let t = String(out)
        return n > max ? String(t.prefix(max - 1)) + "…" : t
    }

    /// Whether `needle` is in `s` (byte search for Swift strings, CFString search for bridged ones).
    private static func find(_ needle: String, in s: String) -> Bool {
        let fast = s.utf8.withContiguousStorageIfAvailable { b -> Bool in
            guard let base = b.baseAddress else { return false }
            return needle.utf8CString.withUnsafeBufferPointer { memmem(base, b.count, $0.baseAddress!, $0.count - 1) != nil }
        }
        return fast ?? ((s as NSString).range(of: needle).location != NSNotFound)
    }

    /// The first `max` characters, then "… N more characters".
    private static func clip(_ s: String, _ max: Int) -> String {
        let (head, more) = cut(s, max)
        return more > 0 ? head + "\n… \(more) more characters" : head
    }

    /// The first `max` characters (UTF-16 units, never splitting a character) and how many were left out.
    private static func cut(_ s: String, _ max: Int) -> (String, Int) {
        if let n = s.utf8.withContiguousStorageIfAvailable({ $0.count }), n <= max { return (s, 0) }
        let ns = s as NSString
        guard ns.length > max else { return (s, 0) }
        let at = ns.rangeOfComposedCharacterSequence(at: max).location
        return (ns.substring(to: at), ns.length - at)
    }

    /// The folder name Claude Code uses for a cwd: every character outside A–Z, a–z, 0–9 becomes "-".
    private static func encode(_ cwd: String) -> String {
        let dash: Unicode.Scalar = "-"
        var out = String.UnicodeScalarView()
        for c in cwd.unicodeScalars {
            let v = c.value
            out.append((v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) ? c : dash)
        }
        return String(out)
    }

    /// "2026-01-02T03:04:05.678Z" → unix seconds, without a date formatter (it's called for every row).
    private static func parseTime(_ s: String) -> Double? {
        var s = s
        return s.withUTF8 { b -> Double? in
            guard b.count >= 19, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A else { return nil }
            func num(_ i: Int, _ n: Int) -> Int? {
                var v = 0
                for k in i..<(i + n) {
                    let c = b[k]
                    guard c >= 0x30, c <= 0x39 else { return nil }
                    v = v * 10 + Int(c - 0x30)
                }
                return v
            }
            guard var y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2),
                  let mi = num(14, 2), let se = num(17, 2), (1...12).contains(mo) else { return nil }
            var frac = 0.0
            var i = 19
            if i < b.count, b[i] == 0x2E {
                i += 1
                var scale = 0.1
                while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { frac += Double(b[i] - 0x30) * scale; scale /= 10; i += 1 }
            }
            var offset = 0
            if i + 5 < b.count, b[i] == 0x2B || b[i] == 0x2D, let oh = num(i + 1, 2), let om = num(i + 4, 2) {
                offset = (oh * 3600 + om * 60) * (b[i] == 0x2B ? 1 : -1)
            }
            // Days from 1970-01-01 (Howard Hinnant's days_from_civil).
            if mo <= 2 { y -= 1 }
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let mp = (mo + 9) % 12
            let doy = (153 * mp + 2) / 5 + d - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146_097 + doe - 719_468
            return Double(days * 86_400 + h * 3600 + mi * 60 + se - offset) + frac
        }
    }
}
