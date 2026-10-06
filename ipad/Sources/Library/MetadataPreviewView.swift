import SwiftUI

struct MetadataPreviewView: View {
  let applied: () -> Void
  @State private var model: MetadataPreviewModel
  @Environment(\.dismiss) private var dismiss

  init(
    api: BookOrbitAPI, bookID: Int, source: MetadataPreviewSource, draft: MetadataDraft,
    applied: @escaping () -> Void
  ) {
    self.applied = applied
    _model = State(
      initialValue: MetadataPreviewModel(api: api, bookID: bookID, source: source, draft: draft))
  }

  var body: some View {
    Group {
      if let offer = model.offer {
        MetadataComparisonView(api: model.api, offer: offer, draft: model.draft, applied: applied)
      } else {
        VStack(spacing: 0) {
          Text(model.source.label).font(.title2).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader).padding()
          ScrollView {
            VStack(alignment: .leading, spacing: 20) {
              if model.isLoading { ProgressView("Loading metadata preview…") }
              if let error = model.error {
                Text(error).fixedSize(horizontal: false, vertical: true)
                  .accessibilityIdentifier("metadataPreviewError")
              }
              if model.hasLoaded {
                Text(model.summary).fixedSize(horizontal: false, vertical: true)
                  .accessibilityIdentifier("metadataPreviewSummary")
              }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
          }
          HStack {
            Button(action: dismiss.callAsFunction) {
              Text("Cancel").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            Spacer()
            if !model.isLoading {
              Button(action: model.load) {
                Text("Try again").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
              }.accessibilityIdentifier("metadataPreviewRetry")
            }
          }.font(.body).buttonStyle(.plain).padding(.horizontal)
        }
      }
    }
    .foregroundStyle(Color(uiColor: .label)).background(Color(uiColor: .systemBackground))
    .task { model.load() }
    .onDisappear(perform: model.cancel)
  }
}
