import CryptoKit
import Foundation
import ImageIO
import Network

@MainActor
final class LoopbackServer {
    let token = UUID().uuidString
    private let publication: Publication
    private let api: Transport
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var listener: NWListener?
    private var activeResponses = 0
    private var waitingResponses: [CheckedContinuation<Bool, Never>] = []
    private var connections: [UUID: NWConnection] = [:]
    private(set) var url: URL?

    init(publication: Publication, api: Transport) {
        self.publication = publication
        self.api = api
    }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, let continuation = self.startContinuation else { return }
                    if case .ready = state, let port = listener.port,
                       let address = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.token)/index.html") {
                        self.startContinuation = nil
                        self.url = address
                        continuation.resume(returning: address)
                    } else if case .failed(let error) = state {
                        self.startContinuation = nil
                        continuation.resume(throwing: error)
                    } else if case .cancelled = state {
                        self.startContinuation = nil
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
            listener.start(queue: DispatchQueue(label: "BookOrbit.reader.loopback"))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        for waiter in waitingResponses { waiter.resume(returning: false) }
        waitingResponses.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.connections.removeValue(forKey: id)?.cancel()
        }
        receive(connection, id: id, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - accumulated.count) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var input = accumulated
                if let data { input.append(data) }
                if input.range(of: Data("\r\n\r\n".utf8)) != nil {
                    await self.respond(connection, id: id, input: input)
                } else if input.count >= 8192 || complete || error != nil {
                    self.connections.removeValue(forKey: id)?.cancel()
                } else { self.receive(connection, id: id, accumulated: input) }
            }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, input: Data) async {
        guard await acquireResponse() else { return }
        defer {
            connections.removeValue(forKey: id)?.cancel()
            if waitingResponses.isEmpty { activeResponses -= 1 }
            else { waitingResponses.removeFirst().resume(returning: true) }
        }
        do {
            guard let text = String(data: input, encoding: .utf8), let url else { return }
            let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1",
                  lines.contains(where: { $0.lowercased() == "host: 127.0.0.1:\(url.port!)" }),
                  first[1].hasPrefix("/\(token)/"), !first[1].contains("%"), !first[1].contains("..") else { return }
            let route = String(first[1].dropFirst(token.count + 2))
            let (body, mime) = try await resource(route)
            let csp = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' blob:; img-src blob: data:; font-src blob:; frame-src blob: 'self'; base-uri 'none'; form-action 'none'; object-src 'none'"
            let headers = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nContent-Type: \(mime)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: \(csp)\r\nConnection: close\r\n\r\n"
            try await send(connection, data: Data(headers.utf8))
            for offset in stride(from: 0, to: body.count, by: 64 * 1024) {
                try await send(connection, data: body.subdata(in: offset..<min(offset + 64 * 1024, body.count)))
            }
            try await finish(connection)
        } catch {
            try? await send(connection, data: Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            try? await finish(connection)
        }
    }

    private func finish(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func acquireResponse() async -> Bool {
        if activeResponses < 2 { activeResponses += 1; return true }
        return await withCheckedContinuation { waitingResponses.append($0) }
    }

    private func send(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func resource(_ route: String) async throws -> (Data, String) {
        if route == "manifest.json" { return (try JSONEncoder().encode(publication), "application/json") }
        if route.hasPrefix("member/"), let index = Int(route.dropFirst(7)), publication.members.indices.contains(index) {
            let member = publication.members[index]
            let data = try await api.request("/api/v1/epub-sessions/\(publication.id.uuidString)/members/\(index)", limit: member.bytes)
            guard data.count == member.bytes, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == member.sha256 else {
                throw ReaderFailure.message("Publication resource verification failed.")
            }
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                guard width <= 8192, height <= 8192, width > 0, height > 0, width <= 16_000_000 / height,
                      CGImageSourceGetCount(source) == 1 else { throw ReaderFailure.message("Image exceeds the static reader limits.") }
            }
            return (data, "application/octet-stream")
        }
        let asset: String
        if route == "index.html" || route == "reader.js" || route == "bootstrap.js" { asset = route }
        else if route.hasPrefix("assets/"), !route.dropFirst(7).contains("/"), route.hasSuffix(".js") { asset = route }
        else { throw ReaderFailure.message("Unknown reader resource.") }
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("Reader/\(asset)"),
              let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024 else {
            throw ReaderFailure.message("Trusted reader asset unavailable.")
        }
        return (try Data(contentsOf: path), asset.hasSuffix(".js") ? "text/javascript" : "text/html")
    }
}
