import SwiftUI

struct BookTableQuickView: View {
  let book: BookCard
  let openDetails: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Text(book.title ?? "Untitled book").font(.title)
        ForEach(
          [
            "authors", "seriesName", "seriesIndex", "publishedDate", "format", "readStatus",
            "readingProgress",
          ], id: \.self
        ) { column in
          LabeledContent(
            BookTableColumnSchema.definition(id: column)?.label ?? column,
            value: BookTableColumnSchema.text(book, column: column))
        }
        Button("Book details", action: openDetails).frame(minHeight: 44)
          .accessibilityIdentifier("tableQuickViewDetails")
      }
      .navigationTitle("Quick view")
      .toolbar { Button("Done", action: dismiss.callAsFunction) }
    }
  }
}
