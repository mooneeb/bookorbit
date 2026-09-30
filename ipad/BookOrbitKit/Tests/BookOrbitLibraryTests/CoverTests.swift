import BookOrbitFeatureKit
import BookOrbitLibrary
import BookOrbitTestSupport
import Foundation
import Testing

@Suite struct CoverTests {
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01])

    private func book(id: Int, hasCover: Bool, coverVersion: String? = "v9") -> BookSummary {
        BookSummary(id: id, title: "Dune", authors: [], hasCover: hasCover, coverVersion: coverVersion, files: [])
    }

    @Test func aThumbnailIsFetchedWithTheSessionsAccessToken() async throws {
        let server = StubServer()
        let jpeg = jpeg
        server.route("GET", "/api/v1/books/2/thumbnail") { _ in .data(jpeg, contentType: "image/jpeg") }
        let covers = BookCovers(session: try await server.signedInSession())

        let data = try await covers.thumbnail(for: book(id: 2, hasCover: true))

        #expect(data == jpeg)
        let request = try #require(server.requests("GET", "/api/v1/books/2/thumbnail").first)
        #expect(request.header("Authorization") == "Bearer access-1")
    }

    @Test func aCoverWithoutAVersionIsRequestedWithoutOne() async throws {
        let server = StubServer()
        let jpeg = jpeg
        server.route("GET", "/api/v1/books/2/thumbnail") { _ in .data(jpeg, contentType: "image/jpeg") }
        let covers = BookCovers(session: try await server.signedInSession())

        let data = try await covers.thumbnail(for: book(id: 2, hasCover: true, coverVersion: nil))

        #expect(data == jpeg)
        let request = try #require(server.requests("GET", "/api/v1/books/2/thumbnail").first)
        #expect(request.query == nil)
    }

    @Test func aBookWithoutACoverIsNotRequested() async throws {
        let server = StubServer()
        let covers = BookCovers(session: try await server.signedInSession())

        #expect(try await covers.thumbnail(for: book(id: 3, hasCover: false)) == nil)
        #expect(server.requests("GET", "/api/v1/books/3/thumbnail").isEmpty)
    }
}
