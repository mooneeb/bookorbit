#if os(iOS)
import BookOrbitAuth
import BookOrbitFeatureKit
import SwiftUI

public enum LibraryFeature {
    public static let screen = FeatureScreen(id: "library", label: FeatureLabel("Library", systemImage: "books.vertical")) { context in
        AnyView(BookListScreen(context: context))
    }
}

struct BookListScreen: View {
    let context: FeatureContext
    @State private var list: BookList?

    var body: some View {
        NavigationStack {
            Group {
                if let list {
                    BookListContent(list: list, covers: BookCovers(session: context.session))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: BookSummary.self) { book in
                BookDetailView(book: book, context: context)
            }
        }
        .task { await loadFirstPage() }
    }

    private func loadFirstPage() async {
        guard list == nil else { return }
        let list = BookList(session: context.session)
        self.list = list
        await list.loadMore()
    }
}

struct BookListContent: View {
    let list: BookList
    let covers: BookCovers

    var body: some View {
        List {
            ForEach(list.books) { book in
                NavigationLink(value: book) {
                    BookRow(book: book, covers: covers)
                }
                .task { await list.loadMoreIfNeeded(after: book) }
            }
            if let failure = list.failure {
                LoadFailureRow(failure: failure, retry: retry)
            } else if list.hasMore {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .overlay {
            if list.books.isEmpty && !list.hasMore && list.failure == nil {
                ContentUnavailableView("No Books", systemImage: "books.vertical")
            }
        }
    }

    private func retry() {
        Task { await list.loadMore() }
    }
}

struct LoadFailureRow: View {
    let failure: SessionError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(failure.userMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try Again", action: retry)
        }
        .frame(maxWidth: .infinity)
    }
}

struct BookRow: View {
    let book: BookSummary
    let covers: BookCovers

    var body: some View {
        HStack(spacing: 12) {
            CoverThumbnail(book: book, covers: covers)
                .frame(width: 44, height: 66)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.headline).lineLimit(2)
                if !book.authors.isEmpty {
                    Text(book.authors.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct CoverThumbnail: View {
    let book: BookSummary
    let covers: BookCovers
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "book.closed").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: book.coverVersion) { await loadImage() }
    }

    private func loadImage() async {
        image = await covers.thumbnailImage(for: book)
    }
}
#endif
