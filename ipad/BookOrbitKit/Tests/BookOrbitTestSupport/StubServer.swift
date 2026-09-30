import Foundation
import Synchronization

/// A fake BookOrbit server faked at the URL loading layer. Each instance owns a unique host, so
/// tests running in parallel never see each other's routes or requests.
public final class StubServer: Sendable {
    public struct Request: Sendable {
        public let method: String
        public let path: String
        public let headers: [String: String]
        public let body: Data

        public func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        public func jsonBody() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    public struct Response: Sendable {
        public let status: Int
        public let body: Data
        public let contentType: String?

        public static func json(_ status: Int = 200, _ object: Any) -> Response {
            Response(status: status, body: try! JSONSerialization.data(withJSONObject: object), contentType: "application/json")
        }

        public static func data(_ data: Data, contentType: String, status: Int = 200) -> Response {
            Response(status: status, body: data, contentType: contentType)
        }

        public static func status(_ status: Int) -> Response {
            Response(status: status, body: Data(), contentType: nil)
        }
    }

    public typealias Handler = @Sendable (Request) -> Response

    public let baseURL: URL
    private let host: String
    private let state = Mutex<State>(State())

    private struct State {
        var routes: [String: Handler] = [:]
        var requests: [Request] = []
        var unreachable = false
    }

    public init() {
        host = "stub-\(UUID().uuidString.lowercased()).bookorbit.test"
        baseURL = URL(string: "https://\(host)")!
        StubURLProtocol.register(self, for: host)
    }

    deinit {
        StubURLProtocol.unregister(host: host)
    }

    /// A URLSession configuration whose requests are answered by stub servers.
    public static var sessionConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    public func route(_ method: String, _ path: String, _ handler: @escaping Handler) {
        state.withLock { $0.routes["\(method) \(path)"] = handler }
    }

    /// Makes every request fail the way it does when the host cannot be reached (Tailscale off).
    public func goOffline() {
        state.withLock { $0.unreachable = true }
    }

    public func goOnline() {
        state.withLock { $0.unreachable = false }
    }

    public var requests: [Request] {
        state.withLock { $0.requests }
    }

    public func requests(_ method: String, _ path: String) -> [Request] {
        requests.filter { $0.method == method && $0.path == path }
    }

    fileprivate func respond(to request: Request) -> Result<Response, URLError> {
        state.withLock { state in
            if state.unreachable { return .failure(URLError(.cannotConnectToHost)) }
            state.requests.append(request)
            guard let handler = state.routes["\(request.method) \(request.path)"] else {
                return .success(.json(404, ["statusCode": 404, "message": "Not Found"]))
            }
            return .success(handler(request))
        }
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = Mutex<[String: WeakServer]>([:])

    private struct WeakServer {
        weak var server: StubServer?
    }

    static func register(_ server: StubServer, for host: String) {
        servers.withLock { $0[host] = WeakServer(server: server) }
    }

    static func unregister(host: String) {
        _ = servers.withLock { $0.removeValue(forKey: host) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
            let server = Self.servers.withLock({ $0[host]?.server })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }

        let recorded = StubServer.Request(
            method: request.httpMethod ?? "GET",
            path: url.path(),
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.readAll) ?? Data()
        )

        switch server.respond(to: recorded) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let response):
            var headers: [String: String] = [:]
            if let contentType = response.contentType { headers["Content-Type"] = contentType }
            let httpResponse = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
