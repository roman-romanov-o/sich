import Foundation
import Network

/// A minimal loopback HTTP server that serves a static directory (a `likec4 build` SPA)
/// for the lifetime of an open Architecture pane, then dies — "0 RAM again after close".
/// SPAs are unreliable from `file://`, so the pane loads `http://127.0.0.1:<ephemeral>/`.
/// Native `Network.framework` (no dependency); GET-only; unknown routes fall back to
/// `index.html` so client-side deep links (`#/task-03-quota-flow`) resolve.
// ponytail: NWListener over a dependency. Ceiling: single-file-per-connection, no keep-alive,
// no range requests — fine for a local static SPA; revisit only if likec4 output needs them.
public final class StaticFileServer: @unchecked Sendable {   // all mutable state serialized on `queue`
    private let root: URL
    private let queue = DispatchQueue(label: "ghostling.likec4.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var reported = false   // owned by `queue` (stateUpdateHandler runs there)

    public init(root: URL) { self.root = root }

    /// Bind an ephemeral loopback port and call `ready` with the base URL (or nil on
    /// failure). Non-blocking so the caller never stalls the main thread.
    public func start(_ ready: @escaping @Sendable (URL?) -> Void) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: params) else { ready(nil); return }
        self.listener = listener
        listener.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard !reported, let port = listener.port else { return }
                reported = true
                ready(URL(string: "http://127.0.0.1:\(port.rawValue)/"))
            case .failed, .cancelled:
                if !reported { reported = true; ready(nil) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [self] in   // connections is owned by `queue`
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let path = data.flatMap(Self.requestedPath) ?? "/"
            connection.send(content: self.response(for: path), completion: .contentProcessed { _ in
                connection.cancel()
                self.queue.async { self.connections[ObjectIdentifier(connection)] = nil }
            })
        }
    }

    /// Parse the path out of `GET /assets/app.js?x=1 HTTP/1.1`, stripping the query.
    private static func requestedPath(_ data: Data) -> String? {
        guard let line = String(data: data, encoding: .utf8)?
            .split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1].split(separator: "?", maxSplits: 1).first ?? parts[1])
    }

    private func response(for path: String) -> Data {
        let index = root.appendingPathComponent("index.html")
        let file = resolve(path) ?? index   // SPA fallback: any unknown route → index.html
        guard let body = try? Data(contentsOf: file) else {
            return Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(Self.contentType(file))\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    /// Map a URL path to an existing file under `root`, guarding against `..` traversal.
    private func resolve(_ path: String) -> URL? {
        let rel = path == "/" ? "index.html" : String(path.drop { $0 == "/" })
        let candidate = root.appendingPathComponent(rel).standardizedFileURL
        guard candidate.path.hasPrefix(root.standardizedFileURL.path) else { return nil }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir)
        return exists && !isDir.boolValue ? candidate : nil
    }

    private static func contentType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "wasm": return "application/wasm"
        case "woff2": return "font/woff2"
        case "map": return "application/json"
        default: return "application/octet-stream"
        }
    }
}
