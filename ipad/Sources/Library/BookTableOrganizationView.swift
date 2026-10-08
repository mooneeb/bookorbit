import SwiftUI

struct BookTableOrganizationView: View {
  let destination: BookTableOrganizationDestination
  let user: AuthUser?
  let libraryID: Int?
  let seriesCollapse: SeriesCollapsePreferenceModel?
  @Environment(\.dismiss) private var dismiss
  @State private var model: OrganizationDirectoryModel

  init(
    api: BookOrbitAPI, destination: BookTableOrganizationDestination, user: AuthUser?,
    libraryID: Int? = nil, seriesCollapse: SeriesCollapsePreferenceModel? = nil
  ) {
    self.destination = destination
    self.user = user
    self.libraryID = libraryID
    self.seriesCollapse = seriesCollapse
    let model = OrganizationDirectoryModel(api: api, kind: destination.kind)
    model.search = destination.name
    _model = State(initialValue: model)
  }

  var body: some View {
    NavigationStack {
      Group {
        if let selection = destination.selection {
          detail(selection)
        } else {
          VStack(spacing: 0) {
            if let error = model.error {
              ContentUnavailableView {
                Label("Could not load authors", systemImage: "wifi.exclamationmark")
              } description: {
                Text(error)
              } actions: {
                Button("Try again") { Task { await model.load() } }
              }
            } else {
              List(model.authors) { author in
                NavigationLink(value: OrganizationSelection(id: author.id, name: author.name)) {
                  VStack(alignment: .leading, spacing: 6) {
                    Text(author.name).font(.headline)
                    Text("\(author.bookCount) books").font(.subheadline)
                  }.padding(.vertical, 8)
                }.accessibilityIdentifier("tableAuthor\(author.id)")
              }
              .overlay {
                if model.total == 0 && !model.isBusy {
                  ContentUnavailableView.search(text: destination.name)
                }
              }
            }
            if model.isBusy { ProgressView("Loading authors…") }
            OrganizationPagingView(
              page: model.page, total: model.total,
              canGoBack: model.canGoBack, canGoNext: model.canGoNext,
              previous: { Task { await model.previousPage() } },
              next: { Task { await model.nextPage() } })
          }
          .navigationTitle(destination.name)
          .navigationDestination(for: OrganizationSelection.self) { detail($0) }
          .task { await model.load() }
        }
      }
      .toolbar { Button("Done", action: dismiss.callAsFunction) }
    }
  }

  private func detail(_ selection: OrganizationSelection) -> some View {
    OrganizationDetailView(
      api: model.api, kind: destination.kind, selection: selection,
      libraryID: libraryID, canEditMetadata: user?.hasPermission(.libraryEditMetadata) == true,
      canRead: user?.hasPermission(.libraryDownload) == true, seriesCollapse: seriesCollapse,
      canDeleteBooks: user?.hasPermission(.libraryDeleteBooks) == true, userID: user?.id ?? 0)
  }
}
