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
    private var modelDir: String = LikeC4.defaultModelDir
    private var deepLinkView: String?
    private var servedBase: URL?
    private var building = false
    private var lastGoodBuild: URL?
    private var pendingRender: DispatchWorkItem?
    private let cliPath: () -> String?
    private let cacheBase: URL?

    private let statusField = NSTextField(labelWithString: "")
    private let errorStrip = NSTextField(labelWithString: "")
    private let sourceView = NSTextView()
    private let sourceScroll = NSScrollView()

    init(
        frame frameRect: NSRect = .zero,
        cliPath: @escaping () -> String? = LikeC4.cliPath,
        cacheBase: URL? = nil
    ) {
        self.cliPath = cliPath
        self.cacheBase = cacheBase
        super.init(frame: frameRect)
        wantsLayer = true
        themedBackground = BoardTheme.documentChrome
        statusField.font = BoardTheme.monoSmall
        statusField.textColor = BoardTheme.textMuted
        statusField.alignment = .center
        statusField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusField)
        errorStrip.font = BoardTheme.monoSmall
        errorStrip.textColor = BoardTheme.attention
        errorStrip.alignment = .center
        errorStrip.wantsLayer = true
        errorStrip.themedBackground = BoardTheme.needsYouCard
        errorStrip.layer?.cornerRadius = 4
        errorStrip.translatesAutoresizingMaskIntoConstraints = false
        errorStrip.isHidden = true
        addSubview(errorStrip)
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
            errorStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            errorStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            errorStrip.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            errorStrip.heightAnchor.constraint(equalToConstant: 24),
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
    private(set) var lastWarning: String?

    /// Open the pane against a bound project, deep-linking to `view` (a `task-NN-*` id or
    /// a saha/v2 `us-001-flow`) when the built site exposes it. `modelDir` selects the
    /// LikeC4 project inside `projectDir` (`docs/architecture` for the repo model,
    /// `model` for a saha/v2 task folder). Idempotent-ish: safe to call on re-show;
    /// re-presenting the same model with a different view only renavigates the hash.
    func present(projectDir: URL, modelDir: String = LikeC4.defaultModelDir,
                 deepLinkView: String?) {
        let sameModel = self.projectDir == projectDir && self.modelDir == modelDir
        self.projectDir = projectDir
        self.modelDir = modelDir
        self.deepLinkView = deepLinkView
        if sameModel, let base = servedBase, webView != nil, server != nil {
            loadWebView(base: base)
            return
        }
        render()
        armWatchers()
    }

    /// Release every resource the pane holds — WebContent process, HTTP server, file
    /// watchers. Called on close so a closed pane costs nothing (design rule 1).
    func teardown() {
        watchers.forEach { $0.stop() }
        watchers.removeAll()
        pendingRender?.cancel()
        pendingRender = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        server?.stop()
        server = nil
        servedBase = nil
        building = false
        errorStrip.isHidden = true
        lastWarning = nil
    }

    private func render() {
        guard let projectDir else { return }
        let content = LikeC4.resolve(projectDir: projectDir, modelDir: modelDir,
                                     cacheBase: cacheBase, cliPath: cliPath())
        lastContent = content
        switch content {
        case .noSources:
            showStatus("No architecture model — add \(modelDir)/*.c4 to this project.", source: nil)
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
        guard let projectDir, let cli = cliPath(), !building else { return }
        building = true
        showStatus("Building architecture model…", source: nil)
        let modelDir = self.modelDir
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = LikeC4.build(cli: cli, projectDir: projectDir, modelDir: modelDir, into: dir)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.building = false
                if ok {
                    self.serve(dir: dir)
                } else {
                    if let lastGoodBuild = self.lastGoodBuild {
                        self.serve(dir: lastGoodBuild, warning: "Build failed — showing last good architecture build.")
                    } else {
                        self.showStatus("Build failed — showing source. \(LikeC4.installHint)",
                                        source: self.concatenatedSource(fallbackSources))
                    }
                }
            }
        }
    }

    // MARK: - Serve + webview

    private func serve(dir: URL, warning: String? = nil) {
        server?.stop()
        let server = StaticFileServer(root: dir)
        self.server = server
        lastGoodBuild = dir
        showStatus("Loading architecture model…", source: nil)
        server.start { base in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let base else {
                    self.showStatus("Could not start the local preview server.", source: nil)
                    return
                }
                self.servedBase = base
                self.loadWebView(base: base)
                self.showWarning(warning)
            }
        }
    }

    private func loadWebView(base: URL) {
        let web = webView ?? makeWebView()
        webView = web
        web.isHidden = false
        statusField.isHidden = true
        sourceScroll.isHidden = true
        web.load(URLRequest(url: Self.deepLinkURL(base: base, view: deepLinkView)))
    }

    /// The built SPA (hash history) routes views at `#/view/<id>/` — a bare
    /// `#/<id>` lands on its 404 page.
    static func deepLinkURL(base: URL, view: String?) -> URL {
        view.map { base.appendingPathComponent("").absoluteString + "#/view/\($0)/" }
            .flatMap(URL.init) ?? base
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: bounds, configuration: config)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.setValue(false, forKey: "drawsBackground")   // let the dark canvas show through while loading
        addSubview(web)
        addSubview(errorStrip, positioned: .above, relativeTo: web)
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
        errorStrip.isHidden = true
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

    private func showWarning(_ message: String?) {
        guard let message else {
            errorStrip.isHidden = true
            lastWarning = nil
            return
        }
        lastWarning = message
        errorStrip.stringValue = message
        errorStrip.isHidden = false
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
        let architectureDir = projectDir.appendingPathComponent(modelDir, isDirectory: true)
        let paths = [architectureDir] + LikeC4.sources(projectDir: projectDir, modelDir: modelDir)
        watchers = paths.map { url in
            FileWatcher(path: url.path) { [weak self] in self?.scheduleRender() }
        }
        watchers.forEach { $0.start() }
    }

    private func scheduleRender() {
        pendingRender?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.render() }
        }
        pendingRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }
}
