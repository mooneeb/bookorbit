import BookOrbitAuth
import SwiftUI

/// The app shell's single extension point. Feature targets describe their top-level screens and
/// reader entry points with these types, and the app lists them once in `FeatureRegistration.swift`.
/// Nothing else in the shell needs editing to add a feature.
public struct FeatureRegistry: Sendable {
    /// Top-level screens, shown as tabs (a sidebar on iPad and Mac), in this order.
    public var screens: [FeatureScreen]
    /// Readers offered on a book's detail page, in this order, when they can open the book.
    public var readers: [ReaderEntryPoint]

    public init(screens: [FeatureScreen], readers: [ReaderEntryPoint]) {
        self.screens = screens
        self.readers = readers
    }

    public func readers(for book: BookSummary) -> [ReaderEntryPoint] {
        readers.filter { $0.canOpen(book) }
    }
}

/// What the shell hands to every feature view.
public struct FeatureContext: Sendable {
    public let session: AuthenticatedSession
    public let registry: FeatureRegistry

    public init(session: AuthenticatedSession, registry: FeatureRegistry) {
        self.session = session
        self.registry = registry
    }
}

public struct FeatureScreen: Identifiable, Sendable {
    public let id: String
    public let title: LocalizedStringResource
    public let systemImage: String
    public let makeView: @MainActor @Sendable (FeatureContext) -> AnyView

    public init(
        id: String,
        title: LocalizedStringResource,
        systemImage: String,
        makeView: @escaping @MainActor @Sendable (FeatureContext) -> AnyView
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.makeView = makeView
    }
}

/// A way to open a book, such as the PDF reader. The shell presents the reader full screen.
public struct ReaderEntryPoint: Identifiable, Sendable {
    public let id: String
    public let title: LocalizedStringResource
    public let systemImage: String
    public let canOpen: @Sendable (BookSummary) -> Bool
    public let makeReader: @MainActor @Sendable (BookSummary, FeatureContext) -> AnyView

    public init(
        id: String,
        title: LocalizedStringResource,
        systemImage: String,
        canOpen: @escaping @Sendable (BookSummary) -> Bool,
        makeReader: @escaping @MainActor @Sendable (BookSummary, FeatureContext) -> AnyView
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.canOpen = canOpen
        self.makeReader = makeReader
    }

    /// A reader for books that have a file in one of `formats` (lowercase, such as `pdf`).
    public init(
        id: String,
        title: LocalizedStringResource,
        systemImage: String,
        formats: Set<String>,
        makeReader: @escaping @MainActor @Sendable (BookSummary, FeatureContext) -> AnyView
    ) {
        self.init(id: id, title: title, systemImage: systemImage, canOpen: { book in book.formats.contains(where: formats.contains) }, makeReader: makeReader)
    }
}
