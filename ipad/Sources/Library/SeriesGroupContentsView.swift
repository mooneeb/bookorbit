import SwiftUI

struct SeriesGroupContentsView: View {
  let api: BookOrbitAPI
  let group: SeriesGroupSelection
  let canEditMetadata: Bool
  let canRead: Bool
  let seriesCollapse: SeriesCollapsePreferenceModel
  var canDeleteBooks = false
  var userID = 0
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      OrganizationDetailView(
        api: api, kind: .series, selection: OrganizationSelection(id: group.id, name: group.name),
        libraryID: group.libraryID, canEditMetadata: canEditMetadata, canRead: canRead,
        seriesCollapse: seriesCollapse, canDeleteBooks: canDeleteBooks, userID: userID
      )
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done", action: dismiss.callAsFunction)
            .frame(minHeight: 44)
            .accessibilityIdentifier("seriesContentsDone")
        }
      }
    }
  }
}
