import BookOrbitReading
import BookOrbitTestSupport
import Foundation
import Testing

private func bookmarkJSON() -> [String: Any] {
    ["id": 5, "bookId": 3, "cfi": "epubcfi(/6/4)", "title": "Chapter 1", "positionSeconds": NSNull(), "createdAt": "2026-09-30T10:00:00.000Z"]
}

@Suite struct ReadingClientTests {
    @Test func aFilesReadingPositionIsFetchedAndSaved() async throws {
        let server = StubServer()
        server.route("GET", "/api/v1/books/files/12/progress") { _ in
            .json(200, ["cfi": NSNull(), "pageNumber": 41, "percentage": 37.5, "positionSeconds": NSNull(), "koreaderProgress": NSNull()])
        }
        server.route("POST", "/api/v1/books/files/12/progress") { _ in .status(201) }
        let reading = ReadingClient(session: try await server.signedInSession())

        let position = try await reading.position(fileId: 12)
        try await reading.savePosition(ReadingPosition(percentage: 38, pageNumber: 42), fileId: 12)

        #expect(position == ReadingPosition(percentage: 37.5, pageNumber: 41))
        let saved = try #require(server.requests("POST", "/api/v1/books/files/12/progress").first).jsonBody()
        #expect(saved["percentage"] as? Double == 38)
        #expect(saved["pageNumber"] as? Int == 42)
    }

    @Test func bookmarksAreListedAddedAndDeleted() async throws {
        let server = StubServer()
        server.route("GET", "/api/v1/books/3/bookmarks") { _ in .json(200, [bookmarkJSON()]) }
        server.route("POST", "/api/v1/books/3/bookmarks") { _ in .json(201, bookmarkJSON()) }
        server.route("DELETE", "/api/v1/books/3/bookmarks/5") { _ in .status(204) }
        let reading = ReadingClient(session: try await server.signedInSession())

        let listed = try await reading.bookmarks(bookId: 3)
        let added = try await reading.addBookmark(bookId: 3, title: "Chapter 1", cfi: "epubcfi(/6/4)")
        try await reading.deleteBookmark(id: added.id, bookId: 3)

        #expect(listed.map(\.title) == ["Chapter 1"])
        #expect(added.id == 5)
        let body = try #require(server.requests("POST", "/api/v1/books/3/bookmarks").first).jsonBody()
        #expect(body["cfi"] as? String == "epubcfi(/6/4)")
        #expect(server.requests("DELETE", "/api/v1/books/3/bookmarks/5").count == 1)
    }

    @Test func aReadingSessionIsRecordedAsAnIOSReadSession() async throws {
        let server = StubServer()
        server.route("POST", "/api/v1/books/files/12/sessions") { _ in .status(204) }
        let reading = ReadingClient(session: try await server.signedInSession())
        let start = Date(timeIntervalSince1970: 1_790_000_000)

        try await reading.recordSession(
            ReadingSessionRecord(id: "s-1", startedAt: start, endedAt: start.addingTimeInterval(125), endPercentage: 40),
            fileId: 12
        )

        let body = try #require(server.requests("POST", "/api/v1/books/files/12/sessions").first).jsonBody()
        #expect(body["sessionId"] as? String == "s-1")
        #expect(body["source"] as? String == "ios")
        #expect(body["sessionType"] as? String == "read")
        #expect(body["durationSeconds"] as? Int == 125)
        #expect(body["endProgress"] as? Double == 40)
        #expect((body["startedAt"] as? String)?.hasPrefix("2026-09-21T") == true)
    }
}
