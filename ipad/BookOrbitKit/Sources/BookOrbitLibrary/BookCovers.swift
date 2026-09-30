import BookOrbitAuth
import BookOrbitFeatureKit
import Foundation
import ImageIO

/// Thumbnails need the access token, so `AsyncImage` cannot load them. The cover version in the
/// URL lets the HTTP cache keep them.
public struct BookCovers: Sendable {
    private let session: AuthenticatedSession

    public init(session: AuthenticatedSession) {
        self.session = session
    }

    public func thumbnail(for book: BookSummary) async throws -> Data? {
        guard book.hasCover else { return nil }
        return try await session.data(
            path: "/api/v1/books/\(book.id)/thumbnail",
            queryItems: book.coverVersion.map { [URLQueryItem(name: "t", value: $0)] } ?? []
        )
    }

    /// Downsampled while decoding, so a long list never holds full-size covers in memory.
    public func thumbnailImage(for book: BookSummary, maxPixelSize: Int = 400) async -> CGImage? {
        guard let data = try? await thumbnail(for: book),
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
