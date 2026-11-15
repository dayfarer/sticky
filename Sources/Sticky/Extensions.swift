// Browser extensions for web stickies, using Apple's WebExtension support (macOS 15.4+).
// Drop an unpacked extension folder into ~/.config/sticky/extensions, or use "Add Extension…".
import AppKit
import WebKit

enum ExtensionsFolder {
    static let url: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/sticky/extensions")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
}

@available(macOS 15.4, *)
@MainActor final class ExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    static let shared = ExtensionHost()

    let controller: WKWebExtensionController
    private(set) var contexts: [WKWebExtensionContext] = []
    private(set) var errors: [String] = []
    /// Where the settings popup appears (the menu bar icon).
    weak var anchor: NSStatusBarButton?

    private override init() {
        controller = WKWebExtensionController(configuration: .default())
        super.init()
        controller.delegate = self
    }

    func loadAll() async {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: ExtensionsFolder.url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) {
            await load(dir)
        }
    }

    func load(_ dir: URL) async {
        do {
            let ext = try await WKWebExtension(resourceBaseURL: dir)
            let ctx = WKWebExtensionContext(for: ext)
            // Stable ID, so the extension's saved settings survive restarts.
            ctx.uniqueIdentifier = "sticky." + dir.lastPathComponent
            ctx.isInspectable = true
            for p in ext.requestedPermissions { ctx.setPermissionStatus(.grantedExplicitly, for: p) }
            for m in ext.allRequestedMatchPatterns { ctx.setPermissionStatus(.grantedExplicitly, for: m) }
            try controller.load(ctx)
            contexts.append(ctx)
        } catch {
            errors.append("\(dir.lastPathComponent): \(error.localizedDescription)")
            print("Extension failed to load: \(dir.lastPathComponent): \(error)")
        }
    }

    func name(_ ctx: WKWebExtensionContext) -> String {
        ctx.webExtension.displayName ?? ctx.uniqueIdentifier
    }

    func hasPopup(_ ctx: WKWebExtensionContext) -> Bool {
        (ctx.action(for: nil) != nil) || ctx.optionsPageURL != nil
    }

    /// Opens the extension's toolbar popup (its settings, for most extensions).
    func openPopup(_ ctx: WKWebExtensionContext) {
        NSApp.activate(ignoringOtherApps: true)
        if (ctx.action(for: nil) != nil) {
            ctx.performAction(for: nil)
        } else if let url = ctx.optionsPageURL {
            openPage(url, title: name(ctx))
        }
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover else {
            completionHandler(nil)
            return
        }
        if let button = anchor {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let view = NSApp.keyWindow?.contentView {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = context.optionsPageURL { openPage(url, title: name(context)) }
        completionHandler(nil)
    }

    // A small floating window for an extension page (options page, etc.).
    private var pages: [NSPanel] = []

    private func openPage(_ url: URL, title: String) {
        let panel = StickyPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.title = title
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let config = WKWebViewConfiguration()
        config.webExtensionController = controller
        let web = WKWebView(frame: panel.contentView!.bounds, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.isInspectable = true
        panel.contentView = web
        web.load(URLRequest(url: url))
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKey()
        pages.append(panel)
    }

    // MARK: Installing

    /// Copies an extension (folder, .zip or .crx) into the extensions folder and loads it.
    func install(from source: URL) async -> String? {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("sticky-ext-\(UUID().uuidString)")
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var root = source
        let ext = source.pathExtension.lowercased()
        if ext == "zip" || ext == "crx" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-q", "-o", source.path, "-d", staging.path]
            try? p.run()
            p.waitUntilExit()
            root = staging
        }
        guard let manifestDir = findManifest(in: root) else {
            return "No manifest.json found. Pick an unpacked extension folder, .zip or .crx."
        }
        var name = (ext == "zip" || ext == "crx") ? source.deletingPathExtension().lastPathComponent
                                                    : manifestDir.lastPathComponent
        name = name.replacingOccurrences(of: "-main", with: "").replacingOccurrences(of: "-master", with: "")
        let dest = ExtensionsFolder.url.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) { return "An extension named “\(name)” is already installed." }
        do {
            try fm.copyItem(at: manifestDir, to: dest)
        } catch {
            return "Couldn't copy the extension: \(error.localizedDescription)"
        }
        let before = errors.count
        await load(dest)
        return errors.count > before ? errors.last : nil
    }

    private func findManifest(in dir: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) { return dir }
        let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for s in subs where fm.fileExists(atPath: s.appendingPathComponent("manifest.json").path) { return s }
        return nil
    }
}
