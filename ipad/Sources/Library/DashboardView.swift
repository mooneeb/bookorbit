import SwiftUI

struct DashboardView: View {
  let canEditMetadata: Bool
  let canRead: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var model: DashboardModel
  @State private var selectedBook: OrganizationSelection?
  @State private var showingSettings = false
  @State private var viewport: CGRect = .null

  init(api: BookOrbitAPI, serverURL: String, user: AuthUser) {
    canEditMetadata = user.hasPermission(.libraryEditMetadata)
    canRead = user.hasPermission(.libraryDownload)
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
              .font(.title2)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityAddTraits(.isHeader)
              if shelf.failed {
                Label("Could not load this shelf", systemImage: "exclamationmark.triangle")
                Button("Try again") { Task { await model.load() } }
              } else if shelf.books.isEmpty {
                Text("No matching books")
              } else {
                DashboardBookRows(
                  api: model.api, rows: bookRows(in: shelf),
                  medium: shelf.configuration.type == "continue-listening" ? .audio : .ebook,
                  namespace: model.coverNamespace, dashboardViewport: viewport
                ) { book in
                  selectedBook = OrganizationSelection(
                    id: book.id, name: book.title ?? "Untitled book")
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
      .onGeometryChange(for: CGRect.self, of: DashboardViewport.frame) { viewport = $0 }
      .foregroundStyle(Color(uiColor: .label))
      .background(Color(uiColor: .systemBackground))
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button(action: dismiss.callAsFunction) {
            Text("Done")
              .font(.body)
              .padding(.horizontal, 16)
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(Color(uiColor: .label))
          Spacer()
          Button {
            Task { await model.load() }
          } label: {
            Text("Refresh")
              .font(.body)
              .padding(.horizontal, 16)
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(Color(uiColor: .label))
          .disabled(model.isBusy || model.isSaving)
          .accessibilityIdentifier("dashboardRefresh")
          Button {
            showingSettings = true
          } label: {
            Text("Shelves")
              .font(.body)
              .padding(.horizontal, 16)
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(Color(uiColor: .label))
          .disabled(model.isBusy || model.isSaving)
          .accessibilityIdentifier("dashboardSettings")
        }
        .padding(.horizontal)
        .background(Color(uiColor: .systemBackground))
      }
      .navigationTitle("Home")
      .task { await model.load() }
      .onDisappear(perform: model.close)
      .sheet(isPresented: $showingSettings) { DashboardSettingsView(model: model) }
      .sheet(
        item: $selectedBook, onDismiss: { Task { await model.load() } },
        content: { book in
          BookDetailView(
            api: model.api, bookID: book.id, canEditMetadata: canEditMetadata, canRead: canRead)
        })
    }
  }

  private func bookRows(in shelf: DashboardShelf) -> [[BookCard]] {
    let rowCount = Int(min(3, max(1, shelf.configuration.rows)))
    let booksPerRow = (shelf.books.count + rowCount - 1) / rowCount
    guard booksPerRow > 0 else { return [] }
    return stride(from: 0, to: shelf.books.count, by: booksPerRow).map { start in
      Array(shelf.books[start..<min(start + booksPerRow, shelf.books.count)])
    }
  }
}

private enum DashboardViewport {
  static func frame(_ geometry: GeometryProxy) -> CGRect {
    let frame = geometry.frame(in: .global)
    let insets = geometry.safeAreaInsets
    return CGRect(
      x: frame.minX + insets.leading, y: frame.minY + insets.top,
      width: max(0, frame.width - insets.leading - insets.trailing),
      height: max(0, frame.height - insets.top - insets.bottom))
  }
}

private struct DashboardBookRows: View {
  let api: BookOrbitAPI
  let rows: [[BookCard]]
  let medium: CoverMedium
  let namespace: String
  let dashboardViewport: CGRect
  let openBook: (BookCard) -> Void
  @State private var shelfViewport: CGRect = .null

  var body: some View {
    ScrollView(.horizontal) {
      VStack(alignment: .leading, spacing: 20) {
        ForEach(rows.indices, id: \.self) { row in
          LazyHStack(alignment: .top, spacing: 16) {
            ForEach(rows[row]) { book in
              Button {
                openBook(book)
              } label: {
                DashboardBookCard(api: api, book: book, medium: medium, namespace: namespace)
              }
              .buttonStyle(.plain)
              .accessibilityHidden(true)
              .background {
                DashboardBookAccessibility(
                  book: book, viewport: dashboardViewport.intersection(shelfViewport)
                ) { openBook(book) }
                .allowsHitTesting(false)
              }
            }
          }
        }
      }
    }
    .onGeometryChange(for: CGRect.self, of: DashboardViewport.frame) { shelfViewport = $0 }
  }
}

private struct DashboardBookAccessibility: UIViewRepresentable {
  let book: BookCard
  let viewport: CGRect
  let openBook: () -> Void

  func makeUIView(context: Context) -> DashboardBookAccessibilityView {
    let view = DashboardBookAccessibilityView()
    view.isUserInteractionEnabled = false
    view.accessibilityTraits = .button
    view.accessibilityHint = "Open book"
    return view
  }

  func updateUIView(_ view: DashboardBookAccessibilityView, context: Context) {
    view.viewport = viewport
    view.openBook = openBook
    view.accessibilityIdentifier = "dashboardBook\(book.id)"
    view.accessibilityLabel = ([book.title ?? "Untitled book"] + book.authors).joined(
      separator: ", ")
    if let progress = book.readingProgress, progress > 0 {
      let percentage = (min(100, max(0, progress)) / 100).formatted(
        .percent.precision(.fractionLength(0)))
      view.accessibilityValue = "Reading progress, \(percentage)"
    } else {
      view.accessibilityValue = nil
    }
  }
}

private final class DashboardBookAccessibilityView: UIView {
  var viewport: CGRect = .null
  var openBook: (() -> Void)?

  private var visibleFrame: CGRect {
    guard let window else { return .null }
    return convert(bounds, to: window).intersection(viewport)
  }

  override var isAccessibilityElement: Bool {
    get { !visibleFrame.isNull && !visibleFrame.isEmpty }
    set {}
  }

  override var accessibilityFrame: CGRect {
    get {
      guard let window, !visibleFrame.isNull else { return .zero }
      return UIAccessibility.convertToScreenCoordinates(visibleFrame, in: window)
    }
    set {}
  }

  override func accessibilityActivate() -> Bool {
    guard isAccessibilityElement, let openBook else { return false }
    openBook()
    return true
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
        let result = try await CoverPreviewLoader.shared.image(
          api: api, book: book, medium: medium, namespace: namespace)
        try Task.checkCancellation()
        image = result
      } catch { image = nil }
    }
  }
}
