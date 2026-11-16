// The ⌃Tab sticky switcher. Hold ⌃ and press Tab to move.
// Let go: the picked sticky goes on top of the current sticky's stack (the current one waits behind it), like tabs.
// Return: the picked sticky opens as its own window instead.
import AppKit

@MainActor final class StickySwitcher: NSObject, NSWindowDelegate {
    static let shared = StickySwitcher()

    private var panel: StickyPanel!
    private let strip = NSStackView()
    private var tiles: [Tile] = []
    private var list: [StickyController] = []
    private var sel = 0
    private var hold: NSEvent.ModifierFlags = []
    private var active = false
    private var poll: Timer?
    private var showTimer: Timer?
    private weak var current: StickyController?  // the sticky that gets swapped out
    private var currentWasFocused = false
    private let hint = NSTextField(labelWithString: "Let go to stack it here  ·  Return to open separately")

    private let tileWidth: CGFloat = 176
    private let thumbHeight: CGFloat = 108

    private override init() {
        super.init()
        panel = StickyPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 18
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        strip.orientation = .horizontal
        strip.spacing = 8
        strip.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        strip.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(strip)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(hint)
        // The panel is as wide as the tiles or the hint, whichever is wider.
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: bg.topAnchor),
            strip.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            strip.leadingAnchor.constraint(greaterThanOrEqualTo: bg.leadingAnchor),
            hint.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: -4),
            hint.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: bg.leadingAnchor, constant: 16),
            hint.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -10),
        ])
    }

    /// A ⌃Tab / ⌃⇧Tab press. The first one opens the switcher; more presses move the highlight.
    func step(back: Bool, holding mods: NSEvent.ModifierFlags, stickies: [StickyController]) {
        if active {
            move(back ? -1 : 1)
            return
        }
        guard !stickies.isEmpty else { NSSound.beep(); return }
        list = stickies
        // The one to swap out: the sticky you're in, or (from another app) the last one you used that's showing.
        let focused = list.first(where: { $0.panel.isKeyWindow })
        currentWasFocused = focused != nil
        current = focused ?? list.first(where: { $0.panel.isVisible })
        // Like ⌘Tab: start on the sticky before the current one.
        let start = (current === list.first && list.count > 1) ? 1 : 0
        sel = back ? list.count - 1 : start
        hold = mods.intersection([.control, .option, .command])
        active = true
        if hold.isEmpty {
            present()  // no key to let go of, so Enter picks
            return
        }
        // A quick tap jumps straight to the last sticky. Holding shows the switcher.
        poll = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated { StickySwitcher.shared.checkRelease() }
        }
        showTimer = Timer.scheduledTimer(withTimeInterval: 0.13, repeats: false) { _ in
            MainActor.assumeIsolated { StickySwitcher.shared.present() }
        }
    }

    private func checkRelease() {
        guard active else { return }
        if NSEvent.modifierFlags.intersection(hold).isEmpty { commit(.swap) }
    }

    private func present() {
        guard active, !panel.isVisible else { return }
        // Fresh pictures of the stickies that are showing (hidden ones keep their last picture).
        for s in list where s.panel.isVisible {
            s.captureThumbnail { [weak self] in self?.refreshTiles() }
        }
        rebuild()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func rebuild() {
        tiles.forEach { $0.removeFromSuperview() }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let n = CGFloat(list.count)
        let width = max(110, min(tileWidth, (area.width - 80 - 24 - (n - 1) * 8) / n))
        tiles = list.enumerated().map { i, s in
            let t = Tile(width: width, thumbHeight: thumbHeight * width / tileWidth)
            t.onClick = { [weak self] in self?.sel = i; self?.commit(.swap) }
            strip.addArrangedSubview(t)
            return t
        }
        refreshTiles()
        hint.stringValue = hold.isEmpty ? "Return to stack it here" : "Let go to stack it here  ·  Return to open separately"
        let size = panel.contentView?.fittingSize ?? strip.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + area.height * 0.08))
    }

    private func refreshTiles() {
        for (i, t) in tiles.enumerated() where i < list.count {
            let s = list[i]
            let stacked = s.config.stack != nil
            let state = s.panel.isVisible ? (s === current ? "current" : "showing")
                : !stacked ? "hidden" : s.config.stack == current?.config.stack ? "behind this one" : "in a stack"
            t.set(title: s.displayTitle, symbol: s.symbolName, state: state,
                  image: s.thumbnail, selected: i == sel)
        }
    }

    private func move(_ d: Int) {
        guard !list.isEmpty else { return }
        sel = ((sel + d) % list.count + list.count) % list.count
        refreshTiles()
    }

    private enum Mode { case swap, separate }

    private func commit(_ mode: Mode) {
        guard active, sel < list.count else { return end() }
        let target = list[sel]
        let out = current
        end()
        guard let app = NSApp.delegate as? AppDelegate else { return }
        switch mode {
        case .swap:
            // Let go: it goes on top of the current sticky's stack. Nothing showing: it comes back on top of its own.
            if let out, out !== target, out.panel.isVisible { app.swap(target, into: out) } else { app.raise(target) }
        case .separate:
            app.showSeparately(target)
        }
    }

    private func cancel() {
        let back = currentWasFocused ? current : nil
        end()
        back?.show()
    }

    private func end() {
        active = false
        poll?.invalidate(); poll = nil
        showTimer?.invalidate(); showTimer = nil
        panel.orderOut(nil)
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard active else { return false }
        switch Int(e.keyCode) {
        case 48: move(e.modifierFlags.contains(.shift) ? -1 : 1)  // Tab
        case 123, 126: move(-1)  // ← ↑
        case 124, 125: move(1)  // → ↓
        case 36, 76: commit(hold.isEmpty ? .swap : .separate)  // Return: open on its own (or swap, if there's no key to let go of)
        case 53: cancel()  // Esc
        case 4:  // H: hide the highlighted sticky (in a stack, the next one shows)
            (NSApp.delegate as? AppDelegate)?.dismiss(list[sel])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.refreshTiles() }
        case 13:  // W: close the highlighted sticky for good
            let s = list[sel]
            end()
            (NSApp.delegate as? AppDelegate)?.closeForGood(s)
        default: break
        }
        return true
    }

    func windowDidResignKey(_ n: Notification) {
        if active, panel.isVisible { end() }
    }

    /// Debug: saves a PNG of the switcher.
    func snapshot(to path: String) {
        guard let view = panel.contentView, let layer = view.layer,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        ctx.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.cgContext.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        ctx.cgContext.scaleBy(x: 2, y: 2)
        layer.render(in: ctx.cgContext)  // draws the pictures too, which cacheDisplay skips
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// One sticky in the switcher: a picture, its name, and whether it's hidden.
private final class Tile: NSView {
    var onClick: (() -> Void)?
    private let thumb = NSView()
    private let placeholder = NSImageView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")

    init(width: CGFloat, thumbHeight: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 2
        translatesAutoresizingMaskIntoConstraints = false

        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 7
        thumb.layer?.masksToBounds = true
        thumb.layer?.contentsGravity = .resizeAspectFill
        thumb.layer?.borderWidth = 0.5
        thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        placeholder.symbolConfiguration = .init(pointSize: 30, weight: .light)
        placeholder.contentTintColor = .tertiaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        thumb.addSubview(placeholder)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        state.font = .systemFont(ofSize: 11)
        state.textColor = .secondaryLabelColor
        for v in [thumb, icon, title, state] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            thumb.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            thumb.heightAnchor.constraint(equalToConstant: thumbHeight),
            icon.leadingAnchor.constraint(equalTo: thumb.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            placeholder.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
            title.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 7),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            state.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            state.leadingAnchor.constraint(equalTo: thumb.leadingAnchor),
            state.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(title t: String, symbol: String, state s: String, image: NSImage?, selected: Bool) {
        title.stringValue = t
        state.stringValue = s.isEmpty ? " " : s
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        placeholder.image = image == nil ? NSImage(systemSymbolName: symbol, accessibilityDescription: nil) : nil
        if let image {
            thumb.layer?.contents = image.layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
            thumb.layer?.backgroundColor = nil
        } else {
            thumb.layer?.contents = nil
            thumb.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
        thumb.alphaValue = s == "hidden" ? 0.55 : 1
        layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
