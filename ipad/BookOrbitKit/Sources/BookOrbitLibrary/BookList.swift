import BookOrbitAPI
import BookOrbitAuth
import BookOrbitCore
import BookOrbitFeatureKit
import Foundation
import Observation

@MainActor @Observable
public final class BookList {
    public private(set) var books: [BookSummary] = []
    public private(set) var hasMore = true
    public private(set) var isLoading = false
    public private(set) var failure: SessionError?

    private let session: AuthenticatedSession
    private let pageSize: Int
    private var nextPage = 0

    public init(session: AuthenticatedSession, pageSize: Int = 50) {
        self.session = session
        self.pageSize = pageSize
    }

    public func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let started = ContinuousClock.now

        do {
            let query = Components.Schemas.BookQuery(
                sort: [.init(field: "title", dir: .asc)],
                pagination: .init(page: nextPage, size: pageSize)
            )
            let page = try await session.client.bookControllerGlobalQuery(body: .json(query)).created.body.json
            books.append(contentsOf: page.items.map(BookSummary.init))
            nextPage += 1
            hasMore = page.items.count == pageSize && books.count < page.total
            failure = nil
        } catch {
            Self.log.error("[library.load_page] [fail] page=\(nextPage) size=\(pageSize) durationMs=\(started.millisecondsElapsed) \(failureFields(error)) - loading a page of books failed")
            failure = SessionError(error) ?? .invalidResponse
        }
    }

    /// Called as each row appears; only the last few rows are checked, so it stays constant time
    /// however many books are loaded.
    public func loadMoreIfNeeded(after book: BookSummary) async {
        guard books.suffix(Self.prefetchDistance).contains(where: { $0.id == book.id }) else { return }
        await loadMore()
    }

    private static let prefetchDistance = 10
    private static let log = EventLog(category: "library")
}
