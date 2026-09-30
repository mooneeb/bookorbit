#if os(iOS)
import BookOrbitFeatureKit
import SwiftUI

struct BookDetailView: View {
    let book: BookSummary
    let context: FeatureContext
    @State private var openReader: ReaderEntryPoint?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CoverThumbnail(book: book, covers: BookCovers(session: context.session))
                    .frame(width: 180, height: 270)
                Text(book.title).font(.title).bold().multilineTextAlignment(.center)
                if !book.authors.isEmpty {
                    Text(book.authors.joined(separator: ", ")).foregroundStyle(.secondary)
                }
                if !book.formats.isEmpty {
                    Text(book.formats.map { $0.uppercased() }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                readerButtons
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $openReader) { reader in
            reader.makeReader(book, context)
        }
    }

    @ViewBuilder private var readerButtons: some View {
        let readers = context.registry.readers(for: book)
        if readers.isEmpty {
            Text("No reader for this book yet.").foregroundStyle(.secondary)
        } else {
            ForEach(readers) { reader in
                ReaderButton(reader: reader, open: open)
            }
        }
    }

    private func open(_ reader: ReaderEntryPoint) {
        openReader = reader
    }
}

struct ReaderButton: View {
    let reader: ReaderEntryPoint
    let open: (ReaderEntryPoint) -> Void

    var body: some View {
        Button(action: tapped) {
            Label {
                Text(reader.label.title)
            } icon: {
                Image(systemName: reader.label.systemImage)
            }
        }
        .buttonStyle(.borderedProminent)
    }

    private func tapped() {
        open(reader)
    }
}
#endif
