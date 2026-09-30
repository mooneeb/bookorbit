import BookOrbitAPI

/// What the library list knows about a book: enough to show it and to decide which readers can
/// open it.
public struct BookSummary: Identifiable, Hashable, Sendable {
    public struct File: Hashable, Sendable {
        public let id: Int
        /// Lowercased file format, such as `epub`, `pdf`, or `cbz`.
        public let format: String?
        public let role: String

        public init(id: Int, format: String?, role: String) {
            self.id = id
            self.format = format
            self.role = role
        }
    }

    public let id: Int
    public let title: String
    public let authors: [String]
    public let hasCover: Bool
    /// Changes whenever the cover changes, so cover URLs that include it can be cached forever.
    public let coverVersion: String
    public let files: [File]

    public var formats: [String] { files.compactMap(\.format) }

    public init(id: Int, title: String, authors: [String], hasCover: Bool, coverVersion: String, files: [File]) {
        self.id = id
        self.title = title
        self.authors = authors
        self.hasCover = hasCover
        self.coverVersion = coverVersion
        self.files = files
    }

    public init(_ card: Components.Schemas.BookCard) {
        self.init(
            id: card.id,
            title: card.title ?? "Untitled",
            authors: card.authors,
            hasCover: card.hasCover,
            coverVersion: card.coverVersion,
            files: card.files.map { File(id: $0.id, format: $0.format?.lowercased(), role: $0.role) }
        )
    }
}
