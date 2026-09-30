import BookOrbitAPI
import BookOrbitAuth
import BookOrbitFeatureKit
import Foundation
import Observation

/// The reader's books across all their libraries, sorted by title and loaded one page at a time so
/// libraries with tens of thousands of books stay cheap.
@MainActor @Observable
public final class BookList {
    public private(set) var books: [BookSummary] = []
    public private(set) var hasMore = true
    public private(set) var isLoading = false
    public private(set) var failure: LoadFailure?

    private let session: AuthenticatedSession
    private let pageSize: Int
    private var nextPage = 0

    public init(session: AuthenticatedSession, pageSize: Int = 50) {
        self.session = session
        self.pageSize = pageSize
    }

    /// Loads the next page, unless one is already loading or the end was reached.
    public func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

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
            failure = LoadFailure(error)
        }
    }

    /// Loads the next page when `book` is close to the end of what is loaded.
    public func loadMoreIfNeeded(after book: BookSummary) async {
        guard let index = books.firstIndex(of: book), index >= books.count - 10 else { return }
        await loadMore()
    }
}

public enum LoadFailure: Error, Equatable {
    case serverUnreachable
    case sessionExpired
    case unexpected

    init(_ error: any Error) {
        switch SessionError(error) {
        case .serverUnreachable: self = .serverUnreachable
        case .sessionExpired, .signedOut: self = .sessionExpired
        default: self = .unexpected
        }
    }
}
