import SwiftUI

struct BookTableCellSuggestionsView: View {
  @Bindable var model: BookTableSuggestionsModel
  let query: String
  let choose: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.isLoading { ProgressView("Finding suggestions…") }
      if let error = model.error {
        Text(error).font(.footnote).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("tableSuggestionsError")
        Button("Retry suggestions") { Task { await model.load(query: query, immediately: true) } }
          .frame(minHeight: 44).accessibilityIdentifier("tableSuggestionsRetry")
      }
      if !model.results.isEmpty {
        Text("Existing values").font(.headline)
        ForEach(model.results, id: \.name) { suggestion in
          Button {
            choose(suggestion.name)
          } label: {
            Text(suggestion.name).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain).accessibilityIdentifier("tableSuggestion_\(suggestion.name)")
        }
      }
    }
    .task(id: query) { await model.load(query: query) }
  }
}
