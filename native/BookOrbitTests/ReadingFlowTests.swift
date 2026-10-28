import XCTest
import CryptoKit
import WebKit
@testable import BookOrbit

final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: @Sendable (URLRequest) throws -> (Int, Data) = { _ in (500, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.reply(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func claim() -> Bool { lock.withLock { total += 1; return total == 1 } }
    var count: Int { lock.withLock { total } }
}

@MainActor
final class ReadingFlowTests: XCTestCase {
    func testHTTPSOriginsAndScopeAreRequired() throws {
        for server in ["http://books.example", "https://user:password@books.example", "https://books.example/path", "https://books.example?token=x"] {
            XCTAssertThrowsError(try Transport(server: server))
        }
        XCTAssertNoThrow(try Transport(server: "https://books.example"))
    }

    func testConnectBrowseReadPageAndReturnWithDeniedAndDisconnectedStates() async throws {
        let identity = "118acdd0-c671-48d0-9a88-e89a4778f4db"
        let lease = "791a43bd-e918-4ea3-ad2c-4c1fc4a9bc51"
        let files = [
            ("META-INF/container.xml", """
            <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="decoy.opf" media-type="application/unknown"/><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """),
            ("book.opf", """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">fixture</dc:identifier><dc:title>Readable fixture</dc:title><dc:language>en</dc:language></metadata><manifest><item id="cover" href="cover.bin" media-type="application/xhtml+xml"/><item id="chapter" href="chapter.bin" media-type="application/xhtml+xml"/><item id="logo" href="logo.svg" media-type="image/svg+xml"/></manifest><spine><itemref idref="cover"/><itemref idref="chapter"/></spine></package>
            """),
            ("cover.bin", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Cover</title></head><body><img src=\"logo.svg\" alt=\"Fixture cover\"/></body></html>"),
            ("decoy.opf", "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\"><metadata/><manifest/><spine/></package>"),
            ("logo.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\"><title>Fixture cover</title><rect width=\"100\" height=\"100\"/></svg>"),
            ("chapter.bin", """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title><script>window.webkit.messageHandlers.reader.postMessage({kind:'error',value:'publication script ran'});document.body.textContent='ATTACK';</script></head><body><h1>Readable chapter</h1><p>Original words remain readable.</p><p>Hello&nbsp;world</p><p>\(String(repeating: "Page navigation retains original words. ", count: 600))</p><img src="https://unsolicited.invalid/track.png" alt="Blocked remote image"/></body></html>
            """),
        ]
        let members: [[String: Any]] = files.map { path, text in
            let bytes = Data(text.utf8)
            return ["path": path, "bytes": bytes.count, "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
        }
        let original = Data(repeating: 42, count: 1000)
        let originalHash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let manifest = try JSONSerialization.data(withJSONObject: ["version": 1, "id": lease, "bookId": 7, "fileId": 9,
            "sourceSha256": originalHash, "sourceBytes": 1000, "expiresAt": "2099-01-01T00:00:00Z", "members": members])
        let refreshes = RefreshCounter()
        FixtureProtocol.reply = { request in
            let path = request.url!.path
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired", path != "/api/v1/auth/refresh" { return (401, Data()) }
            let json: String
            switch path {
            case "/api/v1/server-identity": json = "{\"product\":\"bookorbit\",\"protocolVersion\":1,\"instanceId\":\"\(identity)\"}"
            case "/api/v1/auth/login": json = "{\"accessToken\":\"owner-access\",\"refreshToken\":\"owner-refresh\",\"user\":{\"id\":11,\"username\":\"owner\",\"permissions\":[]}}"
            case "/api/v1/auth/refresh":
                guard refreshes.claim() else { return (401, Data()) }
                json = "{\"accessToken\":\"owner-access\",\"refreshToken\":\"rotated-refresh\"}"
            case "/api/v1/auth/me": json = "{\"id\":11,\"username\":\"owner\",\"permissions\":[]}"
            case "/api/v1/books/query": json = "{\"items\":[{\"id\":7,\"title\":\"Readable fixture\",\"files\":[{\"id\":9,\"format\":\"epub\",\"role\":\"primary\"}]}]}"
            case "/api/v1/books/7": json = "{\"id\":7,\"title\":\"Readable fixture\",\"files\":[{\"id\":9,\"format\":\"epub\",\"role\":\"primary\"}]}"
            case "/api/v1/epub-sessions/books/7/files/9": return (200, manifest)
            case let path where path.hasSuffix("/original"): return (200, original)
            case let path where path.contains("/members/"):
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer owner-access", let index = Int(path.split(separator: "/").last!), files.indices.contains(index) else { return (403, Data()) }
                return (200, Data(files[index].1.utf8))
            case let path where path.lowercased() == "/api/v1/epub-sessions/\(lease)": return (200, Data())
            default: return (403, Data())
            }
            return (200, Data(json.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let api = try Transport(server: "https://fixture.example", configuration: configuration)
        let before = try await api.identity()
        let credentials = try await api.login(username: "owner", password: "fixture-only")
        await api.authorize(credentials)
        let account = try await api.account()
        XCTAssertEqual(account.id, credentials.user?.id)
        let after = try await api.identity()
        XCTAssertEqual(before, after)
        let scope = SessionReference(origin: api.origin, identity: before.instanceId, account: account.id)
        defer { CredentialStore().remove(scope: scope) }
        await api.authorize(Credentials(accessToken: "expired", refreshToken: "owner-refresh", user: account), scope: scope)
        async let listing = api.books(query: "Readable", page: 0)
        async let concurrentDetail = api.detail(7)
        let books = try await listing
        _ = try await concurrentDetail
        XCTAssertEqual(refreshes.count, 1)
        XCTAssertEqual(try CredentialStore().load(scope: scope).refreshToken, "rotated-refresh")
        XCTAssertThrowsError(try CredentialStore().load(scope: SessionReference(origin: scope.origin, identity: scope.identity, account: 12)))
        XCTAssertEqual(books.map(\.id), [7])
        let detail = try await api.detail(7)
        let publication = try await api.open(book: detail.id, file: detail.files[0].id)
        let reader = ReaderModel()
        await reader.open(publication: publication, api: api)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first)
        let web = try XCTUnwrap(reader.web)
        web.frame = window.bounds
        window.addSubview(web)
        defer { reader.close(); web.removeFromSuperview() }
        for _ in 0..<100 where !reader.ready && reader.error == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(reader.ready, reader.error ?? "Reader did not open")
        XCTAssertEqual(reader.warning, "Text is unavailable in this image-only section.")
        reader.turn("next")
        var text: String?
        for _ in 0..<100 {
            text = try await reader.web?.evaluateJavaScript("document.querySelector('foliate-view').renderer.getContents().map(x=>x.doc.body.textContent).join(' ')") as? String
            if text?.contains("Original words remain readable.") == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(text?.contains("Original words remain readable.") == true)
        XCTAssertFalse(text?.contains("ATTACK") == true)
        let width = try await web.evaluateJavaScript("document.querySelector('foliate-view').getBoundingClientRect().width") as? Double
        XCTAssertGreaterThan(width ?? 0, 500)
        XCTAssertNotNil(reader.warning)
        reader.turn("next")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(reader.status, "EPUB page changed")
        reader.close()
        XCTAssertNil(reader.web)
        await api.close(publication)
        do { _ = try await api.detail(99); XCTFail("Denied book was exposed") } catch { XCTAssertTrue(error.localizedDescription.contains("cannot access")) }
        let normal = FixtureProtocol.reply
        let chapterIndex = try XCTUnwrap(files.firstIndex(where: { $0.0 == "chapter.bin" }))
        let opfIndex = try XCTUnwrap(files.firstIndex(where: { $0.0 == "book.opf" }))
        let duplicateOPF = files[opfIndex].1.replacingOccurrences(of: "</manifest>", with: "<item id=\"shadow\" href=\"chapter.bin\" media-type=\"text/plain\"/></manifest>")
        let fragmentOPF = files[opfIndex].1.replacingOccurrences(of: "chapter.bin", with: "chapter.bin#x")
        let queryOPF = files[opfIndex].1.replacingOccurrences(of: "chapter.bin", with: "chapter.bin?x")
        let variants: [(Int, Data, String?)] = [
            (chapterIndex, Data(repeating: 32, count: 4 * 1024 * 1024 + 1), nil),
            (chapterIndex, Data(("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head/><body>" + String(repeating: "<i/>", count: 100_001) + "</body></html>").utf8), nil),
            (opfIndex, Data(duplicateOPF.utf8), nil),
            (opfIndex, Data(fragmentOPF.utf8), "chapter.bin#x"),
            (opfIndex, Data(queryOPF.utf8), nil),
        ]
        for (memberIndex, payload, chapterPath) in variants {
            var changed = try JSONSerialization.jsonObject(with: manifest) as! [String: Any]
            var changedMembers = changed["members"] as! [[String: Any]]
            if let chapterPath { changedMembers[chapterIndex]["path"] = chapterPath }
            changedMembers[memberIndex]["bytes"] = payload.count
            changedMembers[memberIndex]["sha256"] = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            changed["members"] = changedMembers
            let encoded = try JSONSerialization.data(withJSONObject: changed)
            FixtureProtocol.reply = { request in
                if request.url!.path == "/api/v1/epub-sessions/books/7/files/9" { return (200, encoded) }
                if request.url!.path.hasSuffix("/members/\(memberIndex)") { return (200, payload) }
                return try normal(request)
            }
            let limited = try await api.open(book: 7, file: 9)
            let refused = ReaderModel()
            await refused.open(publication: limited, api: api)
            let limitedWeb = try XCTUnwrap(refused.web)
            limitedWeb.frame = window.bounds
            window.addSubview(limitedWeb)
            for _ in 0..<100 where !refused.ready && refused.error == nil { try await Task.sleep(for: .milliseconds(100)) }
            refused.turn("next")
            for _ in 0..<100 where refused.error == nil { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertNotNil(refused.error, "Extensionless XHTML exceeded the resource envelope")
            refused.close()
            limitedWeb.removeFromSuperview()
            await api.close(limited)
        }
        FixtureProtocol.reply = { request in
            if request.url!.path.hasSuffix("/original") { return (200, Data(repeating: 43, count: 1000)) }
            return try normal(request)
        }
        do { _ = try await api.open(book: 7, file: 9); XCTFail("Tampered original opened") }
        catch { XCTAssertTrue(error.localizedDescription.contains("verification failed")) }
        FixtureProtocol.reply = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await api.books(query: "", page: 0); XCTFail("Disconnected catalog succeeded") } catch { XCTAssertNotNil(error) }
    }
}
