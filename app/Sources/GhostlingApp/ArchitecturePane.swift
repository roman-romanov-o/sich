import AppKit
import GhostlingCore
import WebKit

/// Planning Mode's optional Architecture pane: the project's LikeC4 model rendered
/// interactively in a `WKWebView`, or a graceful degrade (source + install hint) when the
/// `likec4` CLI is missing — mirroring how mermaid degrades. Costs 0 RAM until `present`
/// and 0 RAM again after `teardown` (the WebContent process exits, the server dies).
@MainActor
final class ArchitecturePane: NSView {
    private var webView: WKWebView?
    private var server: StaticFileServer?
    private var watchers: [FileWatcher] = []
    private var projectDir: URL?
    private var deepLinkView: String?
    private var building = false

    private let statusField = NSTextField(labelWithString: "")
    private let sourceView = NSTextView()
    private let sourceScroll = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = BoardTheme.hex(0x07090C).cgColor
        statusField.font = BoardTheme.monoSmall
        statusField.textColor = BoardTheme.textMuted
        statusField.alignment = .center
        statusField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusField)
        sourceView.isEditable = false
        sourceView.drawsBackground = false
        sourceView.textContainerInset = NSSize(width: 24, height: 20)
        sourceScroll.documentView = sourceView
        sourceScroll.drawsBackground = false
        sourceScroll.hasVerticalScroller = true
        sourceScroll.translatesAutoresizingMaskIntoConstraints = false
        sourceScroll.isHidden = true
        addSubview(sourceScroll)
        NSLayoutConstraint.activate([
            statusField.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusField.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            statusField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            statusField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            sourceScroll.topAnchor.constraint(equalTo: statusField.bottomAnchor, constant: 8),
            sourceScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            sourceScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            sourceScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Test seam: the resolved content the pane last rendered, so a test can assert the
    /// degrade path without pixel inspection.
    private(set) var lastContent: LikeC4Content?

    /// Open the pane against a bound project, deep-linking to `view` (a `task-NN-*` id) when
    /// the built site exposes it. Idempotent-ish: safe to call on re-show.
    func present(projectDir: URL, deepLinkView: String?) {
        self.projectDir = projectDir
        self.deepLinkView = deepLinkView
        render()
        armWatchers()
    }

    /// Release every resource the pane holds — WebContent process, HTTP server, file
    /// watchers. Called on close so a closed pane costs nothing (design rule 1).
    func teardown() {
        watchers.forEach { $0.stop() }
        watchers.removeAll()
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        server?.stop()
        server = nil
        building = false
    }

    private func render() {
        guard let projectDir else { return }
        let content = LikeC4.resolve(projectDir: projectDir)
        lastContent = content
        switch content {
        case .noSources:
            showStatus("No architecture model — add docs/architecture/*.c4 to this project.", source: nil)
        case let .degraded(sources):
            showStatus(LikeC4.installHint, source: concatenatedSource(sources))
        case let .ready(dir):
            serve(dir: dir)
        case let .needsBuild(dir, sources):
            beginBuild(into: dir, fallbackSources: sources)
        }
    }

    // MARK: - Build (transient node process, off the main thread)

    private func beginBuild(into dir: URL, fallbackSources: [URL]) {
        guard let projectDir, let cli = LikeC4.cliPath(), !building else { return }
        building = true
        showStatus("Building architecture model…", source: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = LikeC4.build(cli: cli, projectDir: projectDir, into: dir)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.building = false
                if ok {
                    self.serve(dir: dir)
                } else {
                    // Build failed with no prior good build — fall back to source + error.
                    self.showStatus("Build failed — showing source. \(LikeC4.installHint)",
                                    source: self.concatenatedSource(fallbackSources))
                }
            }
        }
    }

    // MARK: - Serve + webview

    private func serve(dir: URL) {
        server?.stop()
        let server = StaticFileServer(root: dir)
        self.server = server
        showStatus("Loading architecture model…", source: nil)
        server.start { base in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let base else {
                    self.showStatus("Could not start the local preview server.", source: nil)
                    return
                }
                self.loadWebView(base: base)
            }
        }
    }

    private func loadWebView(base: URL) {
        let web = webView ?? makeWebView()
        webView = web
        statusField.isHidden = true
        sourceScroll.isHidden = true
        let target = deepLinkView.map { base.appendingPathComponent("").absoluteString + "#/\($0)" }
            .flatMap(URL.init) ?? base
        web.load(URLRequest(url: target))
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: bounds, configuration: config)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.setValue(false, forKey: "drawsBackground")   // let the dark canvas show through while loading
        addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: leadingAnchor),
            web.trailingAnchor.constraint(equalTo: trailingAnchor),
            web.topAnchor.constraint(equalTo: topAnchor),
            web.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        return web
    }

    // MARK: - Degrade rendering

    private func showStatus(_ message: String, source: String?) {
        webView?.isHidden = true
        statusField.isHidden = false
        statusField.stringValue = message
        if let source {
            sourceScroll.isHidden = false
            sourceView.textStorage?.setAttributedString(NSAttributedString(
                string: source,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: BoardTheme.textPrimary,
                ]))
        } else {
            sourceScroll.isHidden = true
        }
    }

    private func concatenatedSource(_ sources: [URL]) -> String {
        sources.map { url in
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return "// \(url.lastPathComponent)\n\(body)"
        }.joined(separator: "\n\n")
    }

    // MARK: - Rebuild on model edit (debounced by FileWatcher)

    private func armWatchers() {
        watchers.forEach { $0.stop() }
        guard let projectDir else { watchers = []; return }
        watchers = LikeC4.sources(projectDir: projectDir).map { url in
            FileWatcher(path: url.path) { [weak self] in self?.render() }
        }
        watchers.forEach { $0.start() }
    }
}
