import Foundation

@MainActor
enum BookTableLayout {
  static let columns = BookTableColumnSchema.staticColumns
  static let presetColumns = columns.filter { $0 != "lockRow" }
  static let defaults = BookTableColumnSchema.defaultLayout

  static func canonicalID(_ column: String) -> String {
    switch column {
    case "formats": "format"
    case "series": "seriesName"
    case "readProgress": "readingProgress"
    default: column
    }
  }

  static func normalized(
    _ layout: TableLayoutState, customFields: [CustomMetadataFieldSummary] = []
  ) -> TableLayoutState {
    let customIDs = customFields.map { "custom:\($0.id)" }
    var seen = Set<String>()
    let order = (layout.columnOrder + columns + customIDs).map(canonicalID).filter {
      seen.insert($0).inserted
    }
    var hiddenSeen = Set<String>()
    let hidden = (layout.hiddenColumns + customIDs.filter { !layout.columnOrder.contains($0) })
      .map(canonicalID).filter { hiddenSeen.insert($0).inserted }
    var widths: [String: Double] = [:]
    for (column, width) in layout.columnWidths where width.isFinite && width > 0 {
      if column != canonicalID(column), layout.columnWidths[canonicalID(column)] != nil { continue }
      widths[canonicalID(column)] = width
    }
    var pins: [String: String?] = [:]
    for (column, side) in layout.pinnedColumns ?? [:] {
      if column != canonicalID(column),
        layout.pinnedColumns?.index(forKey: canonicalID(column)) != nil
      {
        continue
      }
      if side == nil || side == "left" || side == "right" {
        pins.updateValue(side, forKey: canonicalID(column))
      }
    }
    return TableLayoutState(
      columnOrder: order, hiddenColumns: hidden, columnWidths: widths,
      pinnedColumns: layout.pinnedColumns == nil ? nil : pins)
  }

  static func visible(
    _ layout: TableLayoutState, customFields: [CustomMetadataFieldSummary] = []
  ) -> [String] {
    let normalized = normalized(layout, customFields: customFields)
    return normalized.columnOrder.filter {
      BookTableColumnSchema.definition(id: $0, customFields: customFields) != nil
        && !normalized.hiddenColumns.contains($0)
    }
  }

  static func unavailable(
    _ layout: TableLayoutState, customFields: [CustomMetadataFieldSummary] = []
  ) -> [String] {
    let normalized = normalized(layout)
    return normalized.columnOrder.filter {
      BookTableColumnSchema.definition(id: $0, customFields: customFields) == nil
        && !normalized.hiddenColumns.contains($0)
    }
  }

  static func pinSide(_ column: String, layout: TableLayoutState) -> String? {
    if let pins = layout.pinnedColumns, let index = pins.index(forKey: column) {
      return pins[index].value
    }
    return BookTableColumnSchema.definition(id: column)?.defaultPin
  }

  static func displayOrder(
    _ layout: TableLayoutState, customFields: [CustomMetadataFieldSummary] = []
  ) -> [String] {
    let visible = visible(layout, customFields: customFields)
    return visible.filter { pinSide($0, layout: layout) == "left" }
      + visible.filter { pinSide($0, layout: layout) == nil }
      + visible.filter { pinSide($0, layout: layout) == "right" }
  }

  static func width(_ column: String, layout: TableLayoutState) -> Double {
    if ["cover", "read"].contains(column) {
      return BookTableColumnSchema.definition(id: column)?.defaultWidth ?? 72
    }
    let width =
      layout.columnWidths[column]
      ?? BookTableColumnSchema.definition(id: column)?.defaultWidth ?? 160
    return column == "lockRow" ? max(44, width) : width
  }

  static func label(_ column: String, customFields: [CustomMetadataFieldSummary] = []) -> String {
    BookTableColumnSchema.definition(id: column, customFields: customFields)?.label
      ?? queryFieldLabel(column)
  }

  static func minimumWidth(_ column: String) -> Double {
    let width = BookTableColumnSchema.definition(id: column)?.minimumWidth ?? 80
    return column == "lockRow" ? max(44, width) : width
  }

  static func isResizable(_ column: String) -> Bool { !["cover", "read"].contains(column) }

  static func validate(_ layout: TableLayoutState) throws {
    let ids =
      layout.columnOrder + layout.hiddenColumns + Array(layout.columnWidths.keys)
      + Array((layout.pinnedColumns ?? [:]).keys)
    guard layout.columnOrder.count <= 2048, layout.hiddenColumns.count <= 2048,
      layout.columnWidths.count <= 2048, (layout.pinnedColumns?.count ?? 0) <= 2048,
      ids.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
      layout.columnWidths.values.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 800 }),
      (layout.pinnedColumns ?? [:]).values.allSatisfy({ $0 == nil || $0 == "left" || $0 == "right" }
      )
    else { throw TablePresetError.layout }
  }

  static func text(_ book: BookCard, column: String) -> String {
    BookTableColumnSchema.text(book, column: column)
  }
}
