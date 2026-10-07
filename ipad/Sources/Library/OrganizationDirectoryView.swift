import SwiftUI

struct OrganizationDirectoryView: View {
  let libraries: [Library]
  let canEditMetadata: Bool
  let canRead: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var model: OrganizationDirectoryModel
  @State private var selection: OrganizationSelection?
  @State private var showingFilters = false
  @State private var draftFilters = OrganizationFilters()

  init(
    api: BookOrbitAPI, kind: OrganizationKind, libraries: [Library], canEditMetadata: Bool,
    canRead: Bool
  ) {
    self.libraries = libraries
    self.canEditMetadata = canEditMetadata
    self.canRead = canRead
    _model = State(initialValue: OrganizationDirectoryModel(api: api, kind: kind))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        OrganizationSearchField(
          text: $model.search, prompt: "Search \(model.kind.title.lowercased())"
        ) { Task { await model.load() } }
        .padding(.horizontal)
        .padding(.vertical, 8)
        if let error = model.error {
          loadFailure(error)
        } else {
          List {
            if model.kind == .authors {
              ForEach(model.authors) { author in
                Button {
                  selection = OrganizationSelection(id: author.id, name: author.name)
                } label: {
                  VStack(alignment: .leading, spacing: 6) {
                    Text(author.name).font(.headline)
                    if let sortName = author.sortName { Text(sortName).font(.subheadline) }
                    Text(bookCount(author.bookCount)).font(.subheadline)
                  }
                  .foregroundStyle(Color(uiColor: .label))
                  .padding(.vertical, 8)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("author\(author.id)")
              }
            } else {
              ForEach(model.series) { series in
                Button {
                  selection = OrganizationSelection(id: series.id, name: series.name)
                } label: {
                  VStack(alignment: .leading, spacing: 6) {
                    Text(series.name).font(.headline)
                    Text(series.authors.joined(separator: ", ")).font(.subheadline)
                    Text(
                      "\(bookCount(series.bookCount)), \(series.readCount) read, \(series.readingCount) in progress"
                    )
                    .font(.subheadline)
                    if series.gapCount > 0 {
                      Text("\(series.gapCount) missing volumes").font(.subheadline)
                    }
                    if let next = series.nextTitle { Text("Up next: \(next)").font(.subheadline) }
                  }
                  .foregroundStyle(Color(uiColor: .label))
                  .padding(.vertical, 8)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("series\(series.id)")
              }
            }
          }
          .overlay {
            if model.total == 0 && !model.isBusy {
              emptyDirectory
            }
          }
        }
        if model.isBusy { ProgressView("Loading \(model.kind.title.lowercased())…").padding() }
        HStack {
          Button("Filters") {
            draftFilters = model.filters
            showingFilters = true
          }
          .frame(minHeight: 44)
          .accessibilityIdentifier("organizationFilters")
          Spacer()
          Button("Done", action: dismiss.callAsFunction)
            .frame(minHeight: 44)
            .accessibilityIdentifier("organizationDone")
        }
        .font(.body)
        .buttonStyle(.plain)
        .foregroundStyle(Color(uiColor: .label))
        .padding(.horizontal)
        .background(Color(uiColor: .systemBackground))
        OrganizationPagingView(
          page: model.page, total: model.total,
          canGoBack: model.canGoBack, canGoNext: model.canGoNext,
          previous: { Task { await model.previousPage() } },
          next: { Task { await model.nextPage() } })
      }
      .navigationTitle(model.kind.title)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Picker("Sort by", selection: $model.sort) {
              ForEach(model.kind.sorts, id: \.value) { sort in Text(sort.title).tag(sort.value) }
            }
            Toggle("Descending", isOn: $model.descending)
          } label: {
            Image(systemName: "arrow.up.arrow.down")
              .foregroundStyle(Color(uiColor: .label))
              .frame(minWidth: 44, minHeight: 44)
          }
          .accessibilityLabel("Sort")
          .accessibilityIdentifier("organizationSort")
        }
      }
      .navigationDestination(item: $selection) { selected in
        OrganizationDetailView(
          api: model.api, kind: model.kind, selection: selected,
          libraryID: model.filters.libraryID, canEditMetadata: canEditMetadata, canRead: canRead)
      }
      .onChange(of: model.sort) { Task { await model.load() } }
      .onChange(of: model.descending) { Task { await model.load() } }
      .task { await model.load() }
      .sheet(isPresented: $showingFilters) { filters }
    }
  }

  private func loadFailure(_ error: String) -> some View {
    ScrollView {
      VStack(spacing: 16) {
        Image(systemName: "wifi.exclamationmark")
          .font(.largeTitle)
          .accessibilityHidden(true)
        Text("Could not load \(model.kind.title.lowercased())")
          .font(.title2.bold())
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
        Text(error)
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
        Button {
          Task { await model.load() }
        } label: {
          Text("Try again")
            .font(.body)
            .padding(.horizontal, 16)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .foregroundStyle(Color(uiColor: .label))
      .multilineTextAlignment(.center)
      .padding()
      .frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(uiColor: .systemBackground))
  }

  private var emptyDirectory: some View {
    VStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .font(.largeTitle)
        .accessibilityHidden(true)
      Text("No \(model.kind.title.lowercased()) found")
        .font(.title2.bold())
      Text(
        "Try another search or adjust the filters. Only items in your accessible libraries are shown."
      )
      .font(.body)
      .fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(Color(uiColor: .label))
    .multilineTextAlignment(.center)
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(uiColor: .systemBackground))
  }

  private var filters: some View {
    NavigationStack {
      Form {
        Picker("Library", selection: $draftFilters.libraryID) {
          Text("All accessible libraries").tag(nil as Int?)
          ForEach(libraries) { library in Text(library.name).tag(Optional(library.id)) }
        }
        if model.kind == .authors {
          Picker("Photo", selection: $draftFilters.photo) {
            Text("Any").tag("")
            Text("Has photo").tag("true")
            Text("Missing photo").tag("false")
          }
          Picker("Sort name", selection: $draftFilters.sortName) {
            Text("Any").tag("")
            Text("Has sort name").tag("true")
            Text("Missing sort name").tag("false")
          }
          Toggle("At least two books", isOn: $draftFilters.multipleBooks)
          Toggle("Books added in the last 30 days", isOn: $draftFilters.recent)
        } else {
          Picker("Reading status", selection: $draftFilters.completion) {
            Text("Any").tag("")
            Text("Not started").tag("not_started")
            Text("In progress").tag("in_progress")
            Text("Complete").tag("complete")
            Text("Missing volumes").tag("has_gaps")
          }
          TextField("Author name", text: $draftFilters.author)
        }
        Button("Reset filters") { draftFilters = OrganizationFilters() }
      }
      .navigationTitle("Filters")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingFilters = false } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Apply") {
            model.filters = draftFilters
            showingFilters = false
            Task { await model.load() }
          }
        }
      }
    }
  }
}

struct OrganizationPagingView: View {
  let page: Int
  let total: Int
  let canGoBack: Bool
  let canGoNext: Bool
  let previous: () -> Void
  let next: () -> Void

  var body: some View {
    HStack {
      if canGoBack { Button("Previous", action: previous) }
      Spacer()
      OrganizationPageSummaryView(page: page, total: total)
      Spacer()
      if canGoNext { Button("Next", action: next) }
    }
    .foregroundStyle(Color(uiColor: .label))
    .padding()
    .background(Color(uiColor: .systemBackground))
  }
}

private struct OrganizationPageSummaryView: UIViewRepresentable {
  let page: Int
  let total: Int

  func makeUIView(context: Context) -> UILabel {
    let label = UILabel()
    label.font = .preferredFont(forTextStyle: .subheadline)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .label
    label.backgroundColor = .systemBackground
    label.textAlignment = .center
    label.numberOfLines = 0
    return label
  }

  func updateUIView(_ label: UILabel, context: Context) {
    label.text = "Page \(page + 1), \(total.formatted()) results"
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
    uiView.sizeThatFits(
      CGSize(width: proposal.width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
  }
}

private func bookCount(_ count: Int) -> String {
  count == 1 ? "1 book" : "\(count.formatted()) books"
}
