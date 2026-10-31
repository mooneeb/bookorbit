import XCTest
import CryptoKit
import WebKit
@testable import BookOrbit

@MainActor
final class OfflineFlowTests: XCTestCase {
    func testOnlyOneExplicitBookDownloadCanRunAtATime() async throws {
        let fixture = try OfflineFixture()
        let api = try fixture.transport()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PublicationStore(root: root, scope: fixture.scope, reserveBytes: 0)
        let book = Book(id: 7, title: "QA Prose", files: [BookFile(id: 9, format: "epub", role: "primary")])
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do { try await store.download(book: book, file: 9, api: api); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await succeeded in group { if succeeded { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
        let saved = try await store.books(page: 0)
        XCTAssertEqual(saved.count, 1)
    }

    func testRefuseAnIncompleteOrHostilePackage() async throws {
        let fixture = try OfflineFixture(omitImage: true)
        let api = try fixture.transport()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PublicationStore(root: root, scope: fixture.scope, reserveBytes: 0)
        let book = Book(id: 7, title: "QA Broken", files: [BookFile(id: 9, format: "epub", role: "primary")])
        do {
            try await store.download(book: book, file: 9, api: api)
            XCTFail("A missing indexed image cannot become ready offline")
        } catch { XCTAssertTrue(error.localizedDescription.contains("missing")) }
        let saved = try await store.books(page: 0)
        XCTAssertTrue(saved.isEmpty)
    }

    func testBrowseALargeIsolatedCatalog() async throws {
        FixtureProtocol.reply = { _ in
            let items = (1...101).map { ["id": $0, "title": "Catalog book", "files": []] as [String: Any] }
            return (200, try JSONSerialization.data(withJSONObject: ["items": items]))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let api = try Transport(server: "https://bookorbit-qa.test", configuration: config)
        do {
            _ = try await api.books(query: "QA Prose", page: 0)
            XCTFail("An oversized catalog response must be refused")
        } catch { XCTAssertTrue(error.localizedDescription.contains("page")) }
    }

    func testChooseAndReopenAVerifiedBook() async throws {
        let fixture = try OfflineFixture()
        let api = try fixture.transport()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PublicationStore(root: root, scope: fixture.scope, reserveBytes: 0)
        let empty = try await store.books(page: 0)
        XCTAssertTrue(empty.isEmpty)
        let book = Book(id: 7, title: "QA Prose", files: [BookFile(id: 9, format: "epub", role: "primary")])
        try await store.download(book: book, file: 9, api: api)
        await api.invalidate()
        let reopened = try PublicationStore(root: root, scope: fixture.scope, reserveBytes: 0)
        let books = try await reopened.books(page: 0)
        XCTAssertEqual(books.map(\.title), ["QA Prose"])
        let local = try await reopened.open(book: 7)
        XCTAssertEqual(try Data(contentsOf: local.original), fixture.original)
        let image = try await local.member(4)
        let font = try await local.member(5)
        XCTAssertEqual(image, fixture.image)
        XCTAssertEqual(font, fixture.font)
        let reader = ReaderModel()
        await reader.open(local: local)
        defer { reader.close() }
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
        let chapter = try await web.evaluateJavaScript("document.querySelector('foliate-view').renderer.getContents()[0].doc.body.textContent") as? String
        XCTAssertTrue(chapter?.contains("The moon keeps its own time.") == true)
        reader.turn("next")
        try await Task.sleep(for: .milliseconds(500))
        let second = try await web.evaluateJavaScript("document.querySelector('foliate-view').renderer.getContents()[0].doc.body.textContent") as? String
        XCTAssertTrue(second?.contains("Chapter Two") == true)
        let finalBooks = try await reopened.books(page: 0)
        XCTAssertEqual(finalBooks.count, 1)
        window.isHidden = true
    }
}

struct OfflineFixture {
    let scope = SessionReference(origin: URL(string: "https://bookorbit-qa.test")!, identity: UUID(uuidString: "118acdd0-c671-48d0-9a88-e89a4778f4db")!, account: 11)
    let original = Data(repeating: 42, count: 1000)
    let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=")!
    let font = Data("fixture font bytes".utf8)
    let manifest: Data
    let members: [(String, Data)]

    init(omitImage: Bool = false) throws {
        var files: [(String, Data)] = [
            ("META-INF/container.xml", Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"book.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8)),
            ("book.opf", Data("<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">qa-prose</dc:identifier><dc:title>QA Prose</dc:title><dc:language>en</dc:language></metadata><manifest><item id=\"one\" href=\"one.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"two\" href=\"two.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"image\" href=\"image.png\" media-type=\"image/png\"/><item id=\"font\" href=\"font.woff2\" media-type=\"font/woff2\"/></manifest><spine><itemref idref=\"one\"/><itemref idref=\"two\"/></spine></package>".utf8)),
            ("one.xhtml", Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>One</title></head><body><h1>Chapter One</h1><p>The moon keeps its own time.</p><img src=\"image.png\" alt=\"Moon\"/></body></html>".utf8)),
            ("two.xhtml", Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Two</title></head><body><h1>Chapter Two</h1></body></html>".utf8)),
            ("image.png", image), ("font.woff2", font),
        ]
        if omitImage { files.removeAll { $0.0 == "image.png" } }
        members = files
        manifest = try JSONSerialization.data(withJSONObject: [
            "version": 1, "id": "791a43bd-e918-4ea3-ad2c-4c1fc4a9bc51", "bookId": 7, "fileId": 9,
            "sourceFileId": "491a43bd-e918-4ea3-ad2c-4c1fc4a9bc51", "instanceId": scope.identity.uuidString, "accountId": scope.account,
            "sourceSha256": Self.digest(original), "sourceRevision": Self.digest(original), "sourceBytes": original.count,
            "expiresAt": "2099-01-01T00:00:00Z", "members": members.map { ["path": $0.0, "bytes": $0.1.count, "sha256": Self.digest($0.1)] as [String: Any] },
        ])
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func transport() throws -> Transport {
        let manifest = manifest, members = members, original = original
        FixtureProtocol.reply = { request in
            let path = request.url!.path
            if path.hasSuffix("/files/9") { return (201, manifest) }
            if path.hasSuffix("/original") { return (200, original) }
            if let index = Int(path.split(separator: "/").last ?? ""), path.contains("/members/"), members.indices.contains(index) { return (200, members[index].1) }
            if request.httpMethod == "DELETE" { return (200, Data()) }
            return (503, Data())
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return try Transport(server: scope.origin.absoluteString, configuration: config)
    }
}
