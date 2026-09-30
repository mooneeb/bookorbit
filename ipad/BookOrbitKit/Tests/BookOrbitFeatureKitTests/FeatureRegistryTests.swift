import BookOrbitFeatureKit
import SwiftUI
import Testing

@Suite struct FeatureRegistryTests {
    private func reader(_ id: String, formats: Set<String>) -> ReaderEntryPoint {
        ReaderEntryPoint(id: id, title: "Read", systemImage: "book", formats: formats) { _, _ in AnyView(EmptyView()) }
    }

    private func book(formats: [String]) -> BookSummary {
        BookSummary(
            id: 1, title: "Dune", authors: [], hasCover: false, coverVersion: "1",
            files: formats.enumerated().map { BookSummary.File(id: $0.offset, format: $0.element, role: "primary") }
        )
    }

    @Test func aBookIsOfferedEveryRegisteredReaderForItsFormatsInOrder() {
        let registry = FeatureRegistry(
            screens: [],
            readers: [reader("pdf", formats: ["pdf"]), reader("epub", formats: ["epub"]), reader("comics", formats: ["cbz", "cbr", "cb7"])]
        )

        #expect(registry.readers(for: book(formats: ["epub", "pdf"])).map(\.id) == ["pdf", "epub"])
        #expect(registry.readers(for: book(formats: ["cbr"])).map(\.id) == ["comics"])
        #expect(registry.readers(for: book(formats: ["m4b"])).isEmpty)
    }
}
