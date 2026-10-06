import Foundation

enum BookTableLayout {
  static let columns = ["title", "authors", "formats", "series", "readProgress"]
  static let defaults = TableLayoutState(
    columnOrder: columns, hiddenColumns: ["series", "readProgress"], columnWidths: [:])

  static func normalized(_ layout: TableLayoutState) -> TableLayoutState {
    var seen = Set<String>()
    let order = (layout.columnOrder + columns).filter {
      columns.contains($0) && seen.insert($0).inserted
    }
    var hidden = layout.hiddenColumns.filter { columns.contains($0) }
    if Set(hidden).count == columns.count { hidden.removeAll { $0 == "title" } }
    let widths = layout.columnWidths.filter {
      columns.contains($0.key) && $0.value.isFinite && (120...600).contains($0.value)
    }
    return TableLayoutState(columnOrder: order, hiddenColumns: hidden, columnWidths: widths)
  }

  static func visible(_ layout: TableLayoutState) -> [String] {
    let normalized = normalized(layout)
    return normalized.columnOrder.filter { !normalized.hiddenColumns.contains($0) }
  }

  static func text(_ book: BookCard, column: String) -> String {
    switch column {
    case "title": book.title ?? "Untitled book"
    case "authors": book.authors.isEmpty ? "Unknown author" : book.authors.joined(separator: ", ")
    case "formats":
      book.files.isEmpty
        ? "No files"
        : Set(book.files.map { $0.format?.uppercased() ?? "Unknown format" }).sorted().joined(
          separator: ", ")
    case "series": book.seriesName ?? "No series"
    case "readProgress":
      book.readingProgress.map { "\(Int(min(100, max(0, $0)).rounded()))%" } ?? "Not started"
    default: ""
    }
  }
}
