import XCTest
import WebKit
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
            web.callAsyncJavaScript("const d = document.querySelector('foliate-view').renderer.getContents()[0].doc; await d.images[0].decode(); await d.fonts.load('16px QA'); return JSON.stringify({ imageDecoded: d.images[0].naturalWidth === 1, fontLoaded: Array.from(d.fonts).some(f => f.family === 'QA' && f.status === 'loaded'), fonts: Array.from(d.fonts).map(f => ({ family: f.family, status: f.status })) });", arguments: [:], in: nil, in: .page) { result in
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
        let (api, scope) = try await connect()
        let book = try await detail("QA Fixed", api: api)
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
    }

    func testRefuseAnIncompleteOrHostilePackage() async throws {
        let (api, scope) = try await connect()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PublicationStore(root: root, scope: scope, reserveBytes: 0)
        let valid = try await detail("QA Prose", api: api)
        try await store.download(book: valid, file: XCTUnwrap(valid.files.first).id, api: api)
        for title in ["QA Broken", "QA Traversal"] {
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
        let reader = ReaderModel()
        await reader.open(local: local)
        let (window, web) = try await display(reader)
        defer { reader.close(); window.isHidden = true }
        XCTAssertTrue(reader.warning?.contains("Partial reading") == true)
        let contained = try await web.evaluateJavaScript("(() => { const d = document.querySelector('foliate-view').renderer.getContents()[0].doc; return d.body.textContent.includes('The moon keeps its own time.') && !d.body.textContent.startsWith('ATTACK') && !d.images[1].naturalWidth })()") as? Bool
        XCTAssertEqual(contained, true)
    }

    private func display(_ reader: ReaderModel) async throws -> (UIWindow, WKWebView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
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
