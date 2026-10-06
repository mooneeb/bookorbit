import SwiftUI

struct DashboardView: View {
  let canEditMetadata: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var model: DashboardModel
  @State private var selectedBook: OrganizationSelection?
  @State private var showingSettings = false

  init(api: BookOrbitAPI, serverURL: String, user: AuthUser) {
    canEditMetadata = user.hasPermission(.libraryEditMetadata)
    _model = State(initialValue: DashboardModel(api: api, serverURL: serverURL, user: user))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        if let error = model.error {
          VStack(spacing: 12) {
            Label("Could not load dashboard", systemImage: "wifi.exclamationmark")
            Text(error)
            Button("Try again") { Task { await model.load() } }
          }.padding()
        }
        if model.isBusy { ProgressView("Loading shelves…").padding() }
        LazyVGrid(
          columns: model.configuration.shelfLayout == "two-columns"
            ? [GridItem(.adaptive(minimum: 340), alignment: .top)]
            : [GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 28
        ) {
          ForEach(model.shelves) { shelf in
            VStack(alignment: .leading, spacing: 12) {
              Text(
                shelf.configuration.label.isEmpty
                  ? DashboardShelfType(rawValue: shelf.configuration.type)?.title ?? "Books"
                  : shelf.configuration.label
              )
              .font(.title2).accessibilityAddTraits(.isHeader)
              if shelf.failed {
                Label("Could not load this shelf", systemImage: "exclamationmark.triangle")
                Button("Try again") { Task { await model.load() } }
              } else if shelf.books.isEmpty {
                Text("No matching books")
              } else {
                ScrollView(.horizontal) {
                  LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(shelf.books) { book in
                      Button {
                        selectedBook = OrganizationSelection(
                          id: book.id, name: book.title ?? "Untitled book")
                      } label: {
                        DashboardBookCard(
                          api: model.api, book: book,
                          medium: shelf.configuration.type == "continue-listening"
                            ? .audio : .ebook,
                          namespace: model.coverNamespace)
                      }
                      .buttonStyle(.plain)
                      .accessibilityIdentifier("dashboardBook\(book.id)")
                    }
                  }
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
              Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16)
            )
            .accessibilityIdentifier("dashboardShelf-\(shelf.id)")
          }
        }.padding()
        if model.shelves.isEmpty && !model.isBusy && model.error == nil {
          ContentUnavailableView(
            "No enabled shelves", systemImage: "books.vertical",
            description: Text("Choose Shelves to customize your dashboard."))
        }
      }
      .foregroundStyle(Color(uiColor: .label))
      .background(Color(uiColor: .systemBackground))
      .navigationTitle("Home")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button("Done", action: dismiss.callAsFunction) }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Refresh") { Task { await model.load() } }.disabled(model.isBusy || model.isSaving)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Shelves") { showingSettings = true }.disabled(model.isBusy || model.isSaving)
            .accessibilityIdentifier("dashboardSettings")
        }
      }
      .task { await model.load() }
      .onDisappear(perform: model.close)
      .sheet(isPresented: $showingSettings) { DashboardSettingsView(model: model) }
      .sheet(
        item: $selectedBook, onDismiss: { Task { await model.load() } },
        content: { book in
          BookDetailView(api: model.api, bookID: book.id, canEditMetadata: canEditMetadata)
        })
    }
  }
}

private struct DashboardBookCard: View {
  let api: BookOrbitAPI
  let book: BookCard
  let medium: CoverMedium
  let namespace: String
  @State private var image: UIImage?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Group {
        if let image {
          Image(uiImage: image).resizable().scaledToFit()
        } else {
          Image(systemName: "book.closed").font(.largeTitle)
        }
      }
      .frame(width: 160, height: 200)
      .accessibilityHidden(true)
      Text(book.title ?? "Untitled book").font(.headline)
      Text(book.authors.joined(separator: ", ")).font(.subheadline)
      if let progress = book.readingProgress, progress > 0 {
        ProgressView(value: min(100, max(0, progress)), total: 100)
          .accessibilityLabel("Reading progress")
      }
    }
    .frame(width: 160, alignment: .leading)
    .task(id: book.coverVersion) {
      image = nil
      guard book.hasCover else { return }
      do {
        let result = try await DashboardCoverLoader.shared.image(
          api: api, book: book, medium: medium, namespace: namespace)
        try Task.checkCancellation()
        image = result
      } catch { image = nil }
    }
  }
}
