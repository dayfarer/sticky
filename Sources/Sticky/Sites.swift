// Saved sites and site history, for the "open a site" list (⌘T, ⌘L, New Web Sticky…).
//
// Ranked by relevance, not just recency: how well it matches what you typed, how often and how
// lately you open it, whether you saved it (⌘D), and what you picked before for the same text.
import AppKit

struct SavedSite: Codable {
    var title: String
    var url: String
}

@MainActor final class Sites {
    static let shared = Sites()

    /// Your saved sites. Plain JSON, so you can edit or reorder it by hand.
    static let savedFile: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/sticky")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sites.json")
    }()

    static let historyFile: URL = Store.file.deletingLastPathComponent().appendingPathComponent("site-history.json")

    private struct Visit: Codable {
        var url: String  // where the latest visit started
        var title: String
        var times: [Double]  // the last 30 visits
    }

    private struct History: Codable {
        var sites: [String: Visit] = [:]
        var picks: [String: [String: Int]] = [:]  // typed text → what you picked → how many times
    }

    struct Entry {
        var id: String  // the URL for a saved site, the site (host) for history
        var title: String
        var url: String
        var saved: Bool
        var visits: Int
        var score: Double
    }

    private(set) var saved: [SavedSite] = []
    private var savedModified: Date?
    private var history = History()

    private init() {
        loadSaved()
        if let data = try? Data(contentsOf: Self.historyFile),
           let h = try? JSONDecoder().decode(History.self, from: data) {
            history = h
        } else {
            // First run: start with the sites you already have open.
            for c in Store.load() where c.kind == .web {
                if let s = c.url, let u = URL(string: s) { recordVisit(u, title: "") }
            }
        }
    }

    /// One entry per site: "canvas.example.edu" for any page there, without "www.".
    static func key(for url: URL) -> String? {
        guard url.scheme?.hasPrefix("http") == true, let h = url.host?.lowercased(), !h.isEmpty else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// "canvas.example.edu/courses" — no https://, no www., no trailing slash.
    static func display(_ url: String) -> String {
        var s = url
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: Recording

    func recordVisit(_ url: URL, title: String) {
        guard let k = Self.key(for: url) else { return }
        var v = history.sites[k] ?? Visit(url: url.absoluteString, title: "", times: [])
        v.url = url.absoluteString
        if !title.isEmpty { v.title = title }
        v.times = Array((v.times + [Date().timeIntervalSince1970]).suffix(30))
        history.sites[k] = v
        saveHistory()
    }

    func setTitle(_ title: String, for url: URL) {
        guard let k = Self.key(for: url), history.sites[k] != nil else { return }
        history.sites[k]?.title = title
        saveHistory()
    }

    private func recordPick(_ query: String, id: String) {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        history.picks[q, default: [:]][id, default: 0] += 1
        saveHistory()
    }

    /// ⌘D: saves the page, or removes it if it's already saved. Returns true if it's now saved.
    @discardableResult
    func toggleSaved(_ url: URL, title: String) -> Bool {
        loadSaved()
        if let i = saved.firstIndex(where: { $0.url == url.absoluteString }) {
            saved.remove(at: i)
            writeSaved()
            return false
        }
        let name = title.trimmingCharacters(in: .whitespaces)
        saved.append(SavedSite(title: name.isEmpty ? (url.host ?? url.absoluteString) : name, url: url.absoluteString))
        writeSaved()
        return true
    }

    // MARK: Ranking

    func ranked(_ query: String) -> [Entry] {
        loadSaved()
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        var entries: [Entry] = []
        var savedSites = Set<String>()
        for s in saved {
            guard let u = URL(string: s.url) else { continue }
            let k = Self.key(for: u) ?? s.url
            savedSites.insert(k)
            let v = history.sites[k]
            entries.append(Entry(id: s.url, title: s.title, url: s.url, saved: true,
                                 visits: v?.times.count ?? 0, score: frecency(v) + 150))
        }
        for (k, v) in history.sites where !savedSites.contains(k) {
            entries.append(Entry(id: k, title: v.title.isEmpty ? k : v.title, url: v.url, saved: false,
                                 visits: v.times.count, score: frecency(v)))
        }
        let tokens = q.split(separator: " ").map(String.init)
        // Nothing typed: saved sites first, then the rest, each by how much you use them.
        guard !tokens.isEmpty else {
            return entries.sorted { $0.saved != $1.saved ? $0.saved : $0.score > $1.score }
        }
        let matched: [Entry] = entries.compactMap { e in
            let m = matchScore(e, tokens)
            guard m > 0 else { return nil }
            var e = e
            e.score = m * (e.score + 10) + learned(q, e.id)
            return e
        }
        return matched.sorted { $0.score > $1.score }
    }

    /// Visits count more when they're recent, but a site you open every day beats one you opened once today.
    private func frecency(_ v: Visit?) -> Double {
        guard let v else { return 0 }
        let now = Date().timeIntervalSince1970
        return v.times.reduce(0) { sum, t in
            let days = (now - t) / 86400
            let w: Double = days < 1 ? 100 : days < 4 ? 80 : days < 14 ? 60 : days < 31 ? 40 : days < 90 ? 20 : 10
            return sum + w
        }
    }

    /// 3 = the name or address starts with it, 2 = a word starts with it, 1 = it's somewhere inside.
    private func matchScore(_ e: Entry, _ tokens: [String]) -> Double {
        let title = e.title.lowercased()
        let site = Self.display(e.url).lowercased()
        let isWordBreak: (Character) -> Bool = { !$0.isLetter && !$0.isNumber }
        let words = title.split(whereSeparator: isWordBreak) + site.split(whereSeparator: isWordBreak)
        var total = 0.0
        for t in tokens {
            if title.hasPrefix(t) || site.hasPrefix(t) { total += 3 }
            else if words.contains(where: { $0.hasPrefix(t) }) { total += 2 }
            else if title.contains(t) || site.contains(t) { total += 1 }
            else { return 0 }
        }
        return total / Double(tokens.count)
    }

    /// If you picked this site before after typing the same thing, it wins.
    private func learned(_ q: String, _ id: String) -> Double {
        var n = 0
        for (typed, counts) in history.picks where q.hasPrefix(typed) || typed.hasPrefix(q) {
            n += counts[id] ?? 0
        }
        return Double(min(n, 5)) * 400
    }

    /// What you typed, as a URL: "canvas.com", "localhost:3000", "https://…", or one word → word.com.
    static func typedURL(_ q: String) -> URL? {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if t.contains("://") { return URL(string: t) }
        if t.hasPrefix("localhost") || t.hasPrefix("127.0.0.1") { return URL(string: "http://" + t) }
        return URL(string: "https://" + (t.contains(".") ? t : t + ".com"))
    }

    // MARK: The picker list

    func pickerItems(for query: String, open: @escaping (URL) -> Void) -> [QuickPicker.Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var items: [QuickPicker.Item] = ranked(q).prefix(40).map { e in
            let opens = e.visits == 0 ? "" : e.visits == 1 ? "1 open" : "\(e.visits) opens"
            let detail = [e.saved ? "saved" : "", opens].filter { !$0.isEmpty }.joined(separator: " · ")
            return QuickPicker.Item(title: (e.saved ? "★ " : "") + e.title, subtitle: Self.display(e.url), detail: detail) {
                Sites.shared.recordPick(q, id: e.id)
                if let u = URL(string: e.url) { open(u) }
            }
        }
        guard !q.isEmpty else { return items }
        if let u = Self.typedURL(q) {
            let typed = QuickPicker.Item(title: "Open \(Self.display(u.absoluteString))", detail: "new site") { open(u) }
            // A full address you typed goes first, unless it's already the top match.
            let topIsIt = items.first.map { Self.display($0.subtitle).hasPrefix(Self.display(u.absoluteString)) } ?? false
            if items.isEmpty || (q.contains(".") && !topIsIt) { items.insert(typed, at: 0) } else { items.append(typed) }
        }
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        if let u = c.url {
            items.append(.init(title: "Search the web for “\(q)”", detail: "Google") { open(u) })
        }
        return items
    }

    // MARK: Files

    private func loadSaved() {
        let m = (try? FileManager.default.attributesOfItem(atPath: Self.savedFile.path))?[.modificationDate] as? Date
        guard m == nil || m != savedModified else { return }
        savedModified = m
        guard let data = try? Data(contentsOf: Self.savedFile) else { saved = []; return }
        saved = (try? JSONDecoder().decode([SavedSite].self, from: data)) ?? saved
    }

    private func writeSaved() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? enc.encode(saved) { try? data.write(to: Self.savedFile) }
        savedModified = (try? FileManager.default.attributesOfItem(atPath: Self.savedFile.path))?[.modificationDate] as? Date
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: Self.historyFile) }
    }
}
