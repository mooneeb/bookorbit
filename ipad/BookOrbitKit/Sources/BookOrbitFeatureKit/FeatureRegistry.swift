import BookOrbitAuth
import SwiftUI

/// The app shell's single extension point. The app lists every feature's screens and readers once,
/// in `FeatureRegistration.swift`; nothing else in the shell changes when a feature is added.
public struct FeatureRegistry: Sendable {
    /// Shown as tabs (a sidebar on iPad and Mac), in this order.
    public var screens: [FeatureScreen]
    /// Offered on a book's detail page, in this order, when they can open the book.
    public var readers: [ReaderEntryPoint]

    public init(screens: [FeatureScreen], readers: [ReaderEntryPoint]) {
        self.screens = screens
        self.readers = readers
    }

    public func readers(for book: BookSummary) -> [ReaderEntryPoint] {
        readers.filter { $0.canOpen(book) }
    }
}

public struct FeatureContext: Sendable {
    public let session: AuthenticatedSession
    public let registry: FeatureRegistry

    public init(session: AuthenticatedSession, registry: FeatureRegistry) {
        self.session = session
        self.registry = registry
    }
}

public struct FeatureLabel: Sendable {
    public let title: LocalizedStringResource
    public let systemImage: String

    public init(_ title: LocalizedStringResource, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }
}

public struct FeatureScreen: Identifiable, Sendable {
    public let id: String
    public let label: FeatureLabel
    public let makeView: @MainActor @Sendable (FeatureContext) -> AnyView

    public init(id: String, label: FeatureLabel, makeView: @escaping @MainActor @Sendable (FeatureContext) -> AnyView) {
        self.id = id
        self.label = label
        self.makeView = makeView
    }
}

/// The shell presents the reader full screen; the reader dismisses itself with
/// `@Environment(\.dismiss)`.
public struct ReaderEntryPoint: Identifiable, Sendable {
    public let id: String
    public let label: FeatureLabel
    public let canOpen: @Sendable (BookSummary) -> Bool
    public let makeReader: @MainActor @Sendable (BookSummary, FeatureContext) -> AnyView

    public init(
        id: String,
        label: FeatureLabel,
        canOpen: @escaping @Sendable (BookSummary) -> Bool,
        makeReader: @escaping @MainActor @Sendable (BookSummary, FeatureContext) -> AnyView
    ) {
        self.id = id
        self.label = label
        self.canOpen = canOpen
        self.makeReader = makeReader
    }

    /// `formats` are lowercase, such as `pdf`.
    public init(
        id: String,
        label: FeatureLabel,
        formats: Set<String>,
        makeReader: @escaping @MainActor @Sendable (BookSummary, FeatureContext) -> AnyView
    ) {
        self.init(id: id, label: label, canOpen: { book in book.formats.contains(where: formats.contains) }, makeReader: makeReader)
    }
}
