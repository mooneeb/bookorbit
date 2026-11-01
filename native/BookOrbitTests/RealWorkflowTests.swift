import XCTest
import WebKit
import Darwin
@testable import BookOrbit

final class QAHTTPProtocol: URLProtocol, @unchecked Sendable {
    private var forwardedTask: URLSessionDataTask?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bookorbit-qa.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var forwarded = request
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.scheme = "http"; url.host = "127.0.0.1"; url.port = 55458
        forwarded.url = url.url!
        forwardedTask = URLSession.shared.dataTask(with: forwarded) { data, response, error in
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            guard let http = response as? HTTPURLResponse, let data else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: http.statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwardedTask?.resume()
    }
    override func stopLoading() { forwardedTask?.cancel() }
}

@MainActor
final class RealWorkflowTests: XCTestCase {
    private func connect() async throws -> (Transport, SessionReference) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QAHTTPProtocol.self]
        let api = try Transport(server: "https://bookorbit-qa.test", configuration: config)
        let identity = try await api.identity()
        let credentials = try await api.login(username: "reader-a@example.test", password: "ReaderA-QA-24!")
        await api.authorize(credentials)
        let account = try await api.account()
        let scope = SessionReference(origin: api.origin, identity: identity.instanceId, account: account.id)
        try await api.verifyCapabilities(scope)
        XCTAssertEqual(credentials.user?.id, account.id)
        return (api, scope)
    }

    private func detail(_ title: String, api: Transport) async throws -> Book {
        let matches = try await api.books(query: title, page: 0)
        let book = try XCTUnwrap(matches.first { $0.title == title })
        return try await api.detail(book.id)
    }

    func testChooseAndReopenAVerifiedBook() async throws {
        let (api, scope) = try await connect()
        let book = try await detail("QA Prose", api: api)
        let file = try XCTUnwrap(book.files.first { $0.format == "epub" })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PublicationStore(root: root, scope: scope, reserveBytes: 0)
        try await store.download(book: book, file: file.id, api: api)
        await api.invalidate()
        let reopened = try PublicationStore(root: root, scope: scope, reserveBytes: 0)
        let local = try await reopened.open(book: book.id)
        XCTAssertEqual(local.book.title, "QA Prose")
        let saved = try await reopened.books(page: 0)
        XCTAssertEqual(saved.count, 1)
        let reader = ReaderModel()
        await reader.open(local: local)
        let (window, web) = try await display(reader)
        defer { reader.close(); window.isHidden = true }
        let text = try await web.evaluateJavaScript("document.querySelector('foliate-view').renderer.getContents()[0].doc.body.textContent") as? String
        XCTAssertTrue(text?.contains("The moon keeps its own time.") == true)
        let assetJSON: String = try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript("const d = document.querySelector('foliate-view').renderer.getContents()[0].doc; await d.images[0].decode(); await d.fonts.load('16px QA'); return JSON.stringify({ imageDecoded: d.images[0].naturalWidth === 96, fontLoaded: Array.from(d.fonts).some(f => f.family === 'QA' && f.status === 'loaded'), fonts: Array.from(d.fonts).map(f => ({ family: f.family, status: f.status })) });", arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? String ?? "{}")
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        let assets = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(assetJSON.utf8)) as? [String: Any])
        XCTAssertEqual(assets["imageDecoded"] as? Bool, true, assetJSON)
        XCTAssertEqual(assets["fontLoaded"] as? Bool, true, assetJSON)
        reader.turn("next")
        try await Task.sleep(for: .milliseconds(500))
        let second = try await web.evaluateJavaScript("document.querySelector('foliate-view').renderer.getContents()[0].doc.body.textContent") as? String
        XCTAssertTrue(second?.contains("Chapter Two") == true)
    }

    func testBrowseALargeIsolatedCatalog() async throws {
        let (api, _) = try await connect()
        var ids = Set<Int>()
        for page in 0..<3 {
            let books = try await api.books(query: "", page: page)
            XCTAssertEqual(books.count, 50)
            XCTAssertFalse(books.contains { $0.title == "B Secret" })
            ids.formUnion(books.map(\.id))
        }
        XCTAssertEqual(ids.count, 150)
        let matches = try await api.books(query: "QA Prose", page: 0)
        XCTAssertEqual(matches.map(\.title), ["QA Prose"])
        let secret = try await api.books(query: "B Secret", page: 0)
        XCTAssertTrue(secret.isEmpty)
        var firstTimes: [Double] = [], nextTimes: [Double] = []
        for _ in 0..<30 {
            var start = Date()
            _ = try await api.books(query: "", page: 0)
            firstTimes.append(Date().timeIntervalSince(start) * 1000)
            start = Date()
            _ = try await api.books(query: "", page: 1)
            nextTimes.append(Date().timeIntervalSince(start) * 1000)
        }
        let first = firstTimes.sorted(), next = nextTimes.sorted()
        print("Native catalog 30 runs: first p50=\(first[14]) p95=\(first[28]) ms; next p50=\(next[14]) p95=\(next[28]) ms; failures=0; real loopback HTTP; PostgreSQL buffers retained")
        XCTAssertLessThanOrEqual(first[28], 2000)
        XCTAssertLessThanOrEqual(next[28], 1000)
    }

    func testUniformFixedLayoutEPUBOpens() async throws {
        try await assertPublicationOpens("QA Fixed")
    }

    func testOrdinaryEPUB2Opens() async throws {
        try await assertPublicationOpens("QA EPUB2")
    }

    private func assertPublicationOpens(_ title: String) async throws {
        let (api, scope) = try await connect()
        let book = try await detail(title, api: api)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PublicationStore(root: root, scope: scope, reserveBytes: 0)
        try await store.download(book: book, file: XCTUnwrap(book.files.first).id, api: api)
        let local = try await store.open(book: book.id)
        let reader = ReaderModel()
        await reader.open(local: local)
        let (window, web) = try await display(reader)
        defer { reader.close(); window.isHidden = true }
        let text = try await web.evaluateJavaScript("document.querySelector('foliate-view').renderer.getContents().map(x => x.doc.body.textContent).join(' ')") as? String
        XCTAssertTrue(text?.contains("The moon keeps its own time.") == true)
        if title == "QA EPUB2" {
            let toc = try await web.evaluateJavaScript("document.querySelector('foliate-view').book.toc.map(x => x.label)") as? [String]
            XCTAssertEqual(toc, ["Chapter One", "Chapter Two"])
        }
    }

    func testLibraryModelRestoresVerifiedDownloadsWithoutAConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LibraryModel(storageRoot: root) { origin in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [QAHTTPProtocol.self]
            return try Transport(server: origin, configuration: configuration)
        }
        model.server = "https://bookorbit-qa.test"
        model.username = "reader-a@example.test"
        model.password = "ReaderA-QA-24!"
        await model.connect()
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.scope)
        XCTAssertEqual(model.books.count, 50)
        let api = try XCTUnwrap(model.transport)
        let book = try await detail("QA Prose", api: api)
        try await XCTUnwrap(model.store).download(book: book, file: XCTUnwrap(book.files.first).id, api: api)
        let offline = LibraryModel(storageRoot: root) { _ in throw URLError(.notConnectedToInternet) }
        await offline.restore()
        XCTAssertEqual(offline.scope?.key, model.scope?.key)
        XCTAssertTrue(offline.downloadsOnly)
        XCTAssertEqual(offline.books.map(\.title), ["QA Prose"])
        XCTAssertNil(offline.transport)
        let local = try await XCTUnwrap(offline.store).open(book: book.id)
        XCTAssertEqual(local.book.publisher, "BookOrbit QA")
        await offline.signOut()
        await model.signOut()
    }

    func testRefuseAnIncompleteOrHostilePackage() async throws {
        let canary = URL(string: "http://127.0.0.1:55460")!
        let (_, reachable) = try await URLSession.shared.data(from: canary.appendingPathComponent("probe"))
        XCTAssertEqual((reachable as? HTTPURLResponse)?.statusCode, 200)
        var reset = URLRequest(url: canary.appendingPathComponent("reset"))
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)
        let (api, scope) = try await connect()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PublicationStore(root: root, scope: scope, reserveBytes: 0)
        let valid = try await detail("QA Prose", api: api)
        try await store.download(book: valid, file: XCTUnwrap(valid.files.first).id, api: api)
        for title in ["QA Broken", "QA Traversal", "QA Broken Srcset", "QA Broken Style", "QA Broken Import", "QA Embedded", "QA Media", "QA Vertical", "QA Mixed", "QA Nodes"] {
            let book = try await detail(title, api: api)
            do {
                try await store.download(book: book, file: XCTUnwrap(book.files.first).id, api: api)
                XCTFail("Invalid package became ready: \(title)")
            } catch { XCTAssertTrue(error is ReaderFailure) }
        }
        let retained = try await store.open(book: valid.id)
        XCTAssertEqual(retained.book.title, "QA Prose")
        let hostile = try await detail("QA Hostile", api: api)
        try await store.download(book: hostile, file: XCTUnwrap(hostile.files.first).id, api: api)
        let local = try await store.open(book: hostile.id)
        let section = try XCTUnwrap(local.publication.members.firstIndex { $0.path == "one.xhtml" })
        let hostileBytes = try await local.member(section)
        XCTAssertTrue(String(decoding: hostileBytes, as: UTF8.self).contains("127.0.0.1:55460"))
        let reader = ReaderModel()
        await reader.open(local: local)
        let (window, web) = try await display(reader)
        defer { reader.close(); window.isHidden = true }
        XCTAssertTrue(reader.warning?.contains("Partial reading") == true)
        let contained = try await web.evaluateJavaScript("(() => { const d = document.querySelector('foliate-view').renderer.getContents()[0].doc; return d.body.textContent.includes('The moon keeps its own time.') && !d.body.textContent.startsWith('ATTACK') && !d.images[1].naturalWidth })()") as? Bool
        XCTAssertEqual(contained, true)
        let (observed, _) = try await URLSession.shared.data(from: canary.appendingPathComponent("observations"))
        let observations = try XCTUnwrap(JSONSerialization.jsonObject(with: observed) as? [String: Int])
        XCTAssertEqual(observations["requests"], 0, "Publication script and image requests must not reach the reachable canary")
        let outside = root.appendingPathComponent("outside-publication.js")
        let sentinel = "Private QA marker \(UUID().uuidString)"
        try Data(sentinel.utf8).write(to: outside)
        let assetDirectory = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("Reader/assets")
        let climb = String(repeating: "../", count: assetDirectory.pathComponents.count)
        let relativeFile = climb + String(outside.path.dropFirst())
        let resolved = assetDirectory.appendingPathComponent(relativeFile).standardizedFileURL
        XCTAssertEqual(resolved.path, outside.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: resolved), Data(sentinel.utf8))
        let base = try XCTUnwrap(web.url)
        let prefix = base.deletingLastPathComponent().path + "/"
        let manifest = try await rawLoopbackGET(prefix + "manifest.json", base: base)
        XCTAssertTrue(String(decoding: manifest, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        for route in ["assets/" + relativeFile, "assets/" + relativeFile.replacingOccurrences(of: "../", with: "%2e%2e/"), String(outside.path.dropFirst())] {
            let response = try await rawLoopbackGET(prefix + route, base: base)
            let text = String(decoding: response, as: UTF8.self)
            XCTAssertTrue(response.isEmpty || text.hasPrefix("HTTP/1.1 503"))
            XCTAssertFalse(text.contains(sentinel))
        }
        let stillServing = try await rawLoopbackGET(prefix + "manifest.json", base: base)
        XCTAssertTrue(String(decoding: stillServing, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        let headerEnd = try XCTUnwrap(stillServing.range(of: Data("\r\n\r\n".utf8)))
        let body = stillServing.subdata(in: headerEnd.upperBound..<stillServing.count)
        XCTAssertEqual(try JSONDecoder().decode(Publication.self, from: body).id, local.publication.id)
    }

    private func rawLoopbackGET(_ target: String, base: URL) async throws -> Data {
        let port = try XCTUnwrap(base.port)
        return try await Task.detached {
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socket >= 0 else { throw URLError(.cannotConnectToHost) }
            defer { Darwin.close(socket) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            var noSignal: Int32 = 1
            guard setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw URLError(.cannotConnectToHost) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { throw URLError(.cannotConnectToHost) }
            // A URL client normalizes dot segments before they reach the server.
            let request = Data("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n".utf8)
            try request.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let sent = Darwin.send(socket, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                    guard sent > 0 else { throw URLError(.networkConnectionLost) }
                    offset += sent
                }
            }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.recv(socket, $0.baseAddress, $0.count, 0) }
                if count == 0 || (count < 0 && errno == ECONNRESET) { return result }
                guard count > 0 else { throw URLError(.networkConnectionLost) }
                guard result.count + count <= 8192 else { throw URLError(.dataLengthExceedsMaximum) }
                result.append(contentsOf: buffer.prefix(count))
            }
        }.value
    }

    func testStalledChapterTransitionTearsDownTheContainedHost() async throws {
        let (api, scope) = try await connect()
        let book = try await detail("QA Prose", api: api)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PublicationStore(root: root, scope: scope, reserveBytes: 0)
        try await store.download(book: book, file: XCTUnwrap(book.files.first).id, api: api)
        let local = try await store.open(book: book.id)
        let reader = ReaderModel()
        await reader.open(local: local)
        let (window, web) = try await display(reader)
        defer { reader.close(); window.isHidden = true }
        _ = try await web.evaluateJavaScript("window.readerTurn = () => new Promise(() => {}); undefined")
        reader.turn("next")
        for _ in 0..<120 where reader.error == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(reader.error?.contains("ten seconds") == true)
        XCTAssertNil(reader.web)
        let preserved = try await store.open(book: book.id)
        XCTAssertEqual(preserved.book.title, "QA Prose")
    }

    private func display(_ reader: ReaderModel) async throws -> (UIWindow, WKWebView) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let web = try XCTUnwrap(reader.web)
        web.frame = controller.view.bounds
        controller.view.addSubview(web)
        for _ in 0..<100 where !reader.ready && reader.error == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(reader.error)
        XCTAssertTrue(reader.ready)
        return (window, web)
    }
}
