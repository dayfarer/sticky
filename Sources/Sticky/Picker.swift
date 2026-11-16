// A floating search-and-pick list, used for ⌘P (browse notes) and ⌘K (actions).
import AppKit

@MainActor final class QuickPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    struct Item {
        var title: String
        var subtitle: String = ""  // second line (a note's preview); empty = one-line row
        var detail: String = ""
        var searchText: String = ""
        var run: () -> Void
    }

    static let shared = QuickPicker()

    private let size = NSSize(width: 600, height: 420)
    private var panel: StickyPanel!
    private let field = NSTextField()
    private let table = NSTableView()
    private var all: [Item] = []
    private var shown: [Item] = []
    private var extra: ((String) -> Item?)?
    private var rank: ((String) -> [Item])?  // custom ranking (the site list), instead of the built-in filter

    /// What's typed right now.
    var query: String { field.stringValue.trimmingCharacters(in: .whitespaces) }
    private weak var returnTo: NSWindow?

    private override init() {
        super.init()
        build()
    }

    private func build() {
        panel = StickyPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.autoresizingMask = [.width, .height]
        panel.contentView = bg

        field.frame = NSRect(x: 18, y: size.height - 52, width: size.width - 36, height: 28)
        field.autoresizingMask = [.width, .minYMargin]
        field.font = .systemFont(ofSize: 18)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        bg.addSubview(field)

        let line = NSBox(frame: NSRect(x: 0, y: size.height - 62, width: size.width, height: 1))
        line.boxType = .separator
        line.autoresizingMask = [.width, .minYMargin]
        bg.addSubview(line)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 6, width: size.width, height: size.height - 70))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        col.width = size.width - 24
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .inset
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle  // the one column fills the width
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)
        table.action = #selector(runSelected)
        scroll.documentView = table
        bg.addSubview(scroll)
    }

    func present(placeholder: String, items: [Item], over parent: NSWindow?, extra: ((String) -> Item?)? = nil,
                 rank: ((String) -> [Item])? = nil) {
        all = items
        self.extra = extra
        self.rank = rank
        returnTo = parent
        field.placeholderString = placeholder
        field.stringValue = ""
        refilter()

        let screen = parent?.screen ?? NSScreen.main
        var origin: NSPoint
        if let p = parent {
            origin = NSPoint(x: p.frame.midX - size.width / 2, y: p.frame.maxY - size.height - 30)
        } else {
            let f = screen?.visibleFrame ?? .zero
            origin = NSPoint(x: f.midX - size.width / 2, y: f.midY)
        }
        if let f = screen?.visibleFrame {
            origin.x = min(max(origin.x, f.minX), f.maxX - size.width)
            origin.y = min(max(origin.y, f.minY), f.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(field)
    }

    /// Debug: saves a PNG of the picker (works even if it isn't the focused window).
    func snapshot(to path: String) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func dismiss() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        returnTo?.makeKey()
    }

    private func refilter() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if let rank {
            shown = rank(query)
        } else if q.isEmpty {
            shown = all
        } else {
            let tokens = q.split(separator: " ").map(String.init)
            func has(_ s: String) -> Bool { let l = s.lowercased(); return tokens.allSatisfy { l.contains($0) } }
            let inTitle = all.filter { has($0.title) }
            let inBody = all.filter { !has($0.title) && has($0.title + " " + $0.searchText) }
            shown = inTitle + inBody
            if let e = extra?(field.stringValue.trimmingCharacters(in: .whitespaces)) { shown.append(e) }
        }
        table.reloadData()
        table.sizeLastColumnToFit()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0) }
    }

    @objc private func runSelected() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return }
        let item = shown[row]
        dismiss()
        item.run()
    }

    private func move(_ d: Int) {
        guard !shown.isEmpty else { return }
        let row = min(max(table.selectedRow + d, 0), shown.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // NSTextFieldDelegate
    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }

    // NSWindowDelegate
    func windowDidResignKey(_ n: Notification) {
        panel.orderOut(nil)
    }

    // Table
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        shown[row].subtitle.isEmpty ? 32 : 46
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = shown[row]
        let v = NSView()
        let t = NSTextField(labelWithString: item.title)
        t.font = .systemFont(ofSize: 14, weight: .medium)
        t.lineBreakMode = .byTruncatingTail
        let d = NSTextField(labelWithString: item.detail)
        d.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        d.textColor = .secondaryLabelColor
        d.alignment = .right
        var fields = [t, d]
        let sub = NSTextField(labelWithString: item.subtitle)
        if !item.subtitle.isEmpty {
            sub.font = .systemFont(ofSize: 12)
            sub.textColor = .secondaryLabelColor
            sub.lineBreakMode = .byTruncatingTail
            fields.append(sub)
        }
        for f in fields {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.addSubview(f)
        }
        d.setContentCompressionResistancePriority(.required, for: .horizontal)
        d.setContentHuggingPriority(.required, for: .horizontal)
        var c = [
            t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            d.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            t.trailingAnchor.constraint(lessThanOrEqualTo: d.leadingAnchor, constant: -12),
            d.firstBaselineAnchor.constraint(equalTo: t.firstBaselineAnchor),
        ]
        if item.subtitle.isEmpty {
            c.append(t.centerYAnchor.constraint(equalTo: v.centerYAnchor))
        } else {
            c += [
                t.topAnchor.constraint(equalTo: v.topAnchor, constant: 5),
                sub.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 1),
                sub.leadingAnchor.constraint(equalTo: t.leadingAnchor),
                sub.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -10),
            ]
        }
        NSLayoutConstraint.activate(c)
        return v
    }
}
