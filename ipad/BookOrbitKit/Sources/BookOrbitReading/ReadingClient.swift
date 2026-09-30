import BookOrbitAPI
import BookOrbitAuth
import Foundation

public struct ReadingPosition: Equatable, Sendable {
    /// 0 to 100.
    public var percentage: Double
    /// Set by reflowable readers.
    public var cfi: String?
    /// Set by fixed-layout readers.
    public var pageNumber: Int?

    public init(percentage: Double, cfi: String? = nil, pageNumber: Int? = nil) {
        self.percentage = percentage
        self.cfi = cfi
        self.pageNumber = pageNumber
    }
}

public struct Bookmark: Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let cfi: String?
    public let createdAt: Date
}

public struct ReadingSessionRecord: Equatable, Sendable {
    /// Chosen by the app, so a retried upload of the same session is not counted twice.
    public let id: String
    public let startedAt: Date
    public let endedAt: Date
    public let endPercentage: Double?

    public init(id: String = UUID().uuidString, startedAt: Date, endedAt: Date, endPercentage: Double?) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endPercentage = endPercentage
    }
}

/// The calls every reader shares, so the PDF, EPUB, and comics readers never duplicate them.
/// Throws `SessionError`.
public struct ReadingClient: Sendable {
    private let session: AuthenticatedSession

    public init(session: AuthenticatedSession) {
        self.session = session
    }

    public func position(fileId: Int) async throws -> ReadingPosition {
        let progress = try await call { try await session.client.bookControllerGetFileProgress(path: .init(fileId: fileId)).ok.body.json }
        return ReadingPosition(percentage: progress.percentage, cfi: progress.cfi, pageNumber: progress.pageNumber)
    }

    public func savePosition(_ position: ReadingPosition, fileId: Int) async throws {
        let body = Components.Schemas.SaveProgressDto(cfi: position.cfi, pageNumber: position.pageNumber.map(Double.init), percentage: position.percentage)
        _ = try await call { try await session.client.bookControllerSaveFileProgress(path: .init(fileId: fileId), body: .json(body)).created }
    }

    public func bookmarks(bookId: Int) async throws -> [Bookmark] {
        let rows = try await call { try await session.client.bookmarkControllerGetBookmarks(path: .init(bookId: bookId)).ok.body.json }
        return rows.map(Bookmark.init)
    }

    public func addBookmark(bookId: Int, title: String, cfi: String) async throws -> Bookmark {
        let row = try await call {
            try await session.client.bookmarkControllerCreateBookmark(path: .init(bookId: bookId), body: .json(.init(cfi: cfi, title: title))).created.body.json
        }
        return Bookmark(row)
    }

    public func deleteBookmark(id: Int, bookId: Int) async throws {
        _ = try await call { try await session.client.bookmarkControllerDeleteBookmark(path: .init(bookId: bookId, bookmarkId: id)).noContent }
    }

    public func recordSession(_ record: ReadingSessionRecord, fileId: Int) async throws {
        let body = Components.Schemas.SaveReadingSessionDto(
            sessionId: record.id,
            startedAt: Self.timestamp(record.startedAt),
            endedAt: Self.timestamp(record.endedAt),
            // The server only accepts whole seconds.
            durationSeconds: max(0, record.endedAt.timeIntervalSince(record.startedAt)).rounded(),
            endProgress: record.endPercentage,
            sessionType: .read,
            source: .ios
        )
        _ = try await call { try await session.client.readingSessionControllerSaveSession(path: .init(fileId: fileId), body: .json(body)).noContent }
    }

    private func call<Result>(_ request: () async throws -> Result) async throws -> Result {
        do {
            return try await request()
        } catch {
            throw SessionError(error) ?? .invalidResponse
        }
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }
}

extension Bookmark {
    init(_ row: Components.Schemas.BookmarkResponseDto) {
        self.init(id: Int(row.id), title: row.title, cfi: row.cfi, createdAt: row.createdAt)
    }
}
