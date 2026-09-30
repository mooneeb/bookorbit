import BookOrbitLibrary
import BookOrbitTestSupport
import Foundation
import Testing

private func card(_ id: Int, title: String? = nil, formats: [String] = ["epub"]) -> [String: Any] {
    [
        "id": id, "title": title ?? "Book \(id)", "authors": ["Author \(id)"], "hasCover": id % 2 == 0,
        "coverVersion": "v\(id)", "status": "present", "genres": [],
        "files": formats.enumerated().map { ["id": id * 10 + $0.offset, "format": $0.element, "role": "primary", "sizeBytes": 1] },
    ]
}

/// A library of `total` books served `size` at a time, the way the server pages them.
private func routeLibrary(_ server: StubServer, total: Int) {
    server.route("POST", "/api/v1/books/query") { request in
        let pagination = request.jsonBody()["pagination"] as? [String: Int] ?? [:]
        let page = pagination["page"] ?? 0, size = pagination["size"] ?? 50
        let ids = (page * size)..<min(total, (page + 1) * size)
        return .json(201, ["items": ids.map { card($0 + 1) }, "total": total, "page": page, "size": size])
    }
}

@Suite struct BookListTests {
    @Test func theFirstPageListsBooksByTitle() async throws {
        let server = StubServer()
        routeLibrary(server, total: 3)
        let list = await BookList(session: try await server.signedInSession(), pageSize: 2)

        await list.loadMore()

        #expect(await list.books.map(\.title) == ["Book 1", "Book 2"])
        let query = try #require(server.requests("POST", "/api/v1/books/query").first).jsonBody()
        #expect(query["pagination"] as? [String: Int] == ["page": 0, "size": 2])
        #expect(query["sort"] as? [[String: String]] == [["field": "title", "dir": "asc"]])
    }

    @Test func loadingMorePagesStopsAtTheEndOfTheLibrary() async throws {
        let server = StubServer()
        routeLibrary(server, total: 5)
        let list = await BookList(session: try await server.signedInSession(), pageSize: 2)

        for _ in 0..<5 { await list.loadMore() }

        #expect(await list.books.map(\.id) == [1, 2, 3, 4, 5])
        #expect(await list.hasMore == false)
        #expect(server.requests("POST", "/api/v1/books/query").count == 3)
    }

    @Test func aBookKnowsItsFormatsAndWhetherItHasACover() async throws {
        let server = StubServer()
        server.route("POST", "/api/v1/books/query") { _ in
            .json(201, ["items": [card(2, title: "Dune", formats: ["pdf", "epub"])], "total": 1, "page": 0, "size": 50])
        }
        let list = await BookList(session: try await server.signedInSession())

        await list.loadMore()

        let book = try #require(await list.books.first)
        #expect(book.title == "Dune")
        #expect(book.authors == ["Author 2"])
        #expect(book.formats == ["pdf", "epub"])
        #expect(book.hasCover)
    }

    @Test func aFailedPageIsReportedAndCanBeRetried() async throws {
        let server = StubServer()
        routeLibrary(server, total: 1)
        let list = await BookList(session: try await server.signedInSession())
        server.goOffline()

        await list.loadMore()
        #expect(await list.failure == .serverUnreachable)
        #expect(await list.books.isEmpty)

        server.goOnline()
        await list.loadMore()
        #expect(await list.failure == nil)
        #expect(await list.books.map(\.id) == [1])
    }
}
