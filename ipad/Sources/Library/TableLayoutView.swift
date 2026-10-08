import SwiftUI

struct TableLayoutView: View {
  @Binding var layout: TableLayoutState
  @Binding var density: BookTableDensity
  let customFields: [CustomMetadataFieldSummary]
  let fitWidth: (String) -> Double
  @Environment(\.dismiss) private var dismiss
  @State private var draft: TableLayoutState
  @State private var draftDensity: BookTableDensity

  init(
    layout: Binding<TableLayoutState>, density: Binding<BookTableDensity>,
    customFields: [CustomMetadataFieldSummary] = [], fitWidth: @escaping (String) -> Double
  ) {
    _layout = layout
    _density = density
    self.customFields = customFields
    self.fitWidth = fitWidth
    _draft = State(
      initialValue: BookTableLayout.normalized(layout.wrappedValue, customFields: customFields))
    _draftDensity = State(initialValue: density.wrappedValue)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        List {
          Section("Table appearance") {
            Picker("Table density", selection: $draftDensity) {
              ForEach(BookTableDensity.allCases) { value in Text(value.label).tag(value) }
            }.accessibilityIdentifier("tableDensity")
            Button("Auto-fit all columns", action: fitAll).frame(minHeight: 44)
              .accessibilityIdentifier("autoFitAllTableColumns")
            Text("Auto-fit uses books on the current page.").font(.body)
          }
          ForEach(draft.columnOrder, id: \.self) { column in
            VStack(alignment: .leading, spacing: 10) {
              Toggle(
                BookTableLayout.label(column, customFields: customFields),
                isOn: Binding(
                  get: { !draft.hiddenColumns.contains(column) },
                  set: { visible in
                    if visible {
                      draft.hiddenColumns.removeAll { $0 == column }
                    } else if BookTableColumnSchema.definition(
                      id: column, customFields: customFields) == nil
                      || BookTableLayout.visible(draft, customFields: customFields).count > 1
                    {
                      draft.hiddenColumns.append(column)
                    }
                  })
              ).accessibilityIdentifier("showTableColumn\(column)")
              Stepper(
                "Width: \(Int(BookTableLayout.width(column, layout: draft))) points",
                value: Binding(
                  get: { BookTableLayout.width(column, layout: draft) },
                  set: { draft.columnWidths[column] = $0 }),
                in: BookTableLayout.minimumWidth(column)...800, step: 20
              )
              .disabled(
                draft.hiddenColumns.contains(column) || !BookTableLayout.isResizable(column)
              )
              .accessibilityIdentifier("widthTableColumn\(column)")
              if BookTableColumnSchema.definition(id: column, customFields: customFields) == nil {
                Text(
                  "This column is unavailable at this library location. Its settings are preserved."
                )
                .font(.body).fixedSize(horizontal: false, vertical: true)
              }
              Button("Auto-fit column") { fit(column) }.frame(minHeight: 44)
                .disabled(!BookTableLayout.isResizable(column))
                .accessibilityIdentifier("autoFitTableColumn\(column)")
              Picker(
                "Pin column",
                selection: Binding(
                  get: { BookTableLayout.pinSide(column, layout: draft) ?? "none" },
                  set: { setPin(column, side: $0) })
              ) {
                Text("Unpinned").tag("none")
                Text("Left").tag("left").disabled(!canPin(column, side: "left"))
                Text("Right").tag("right").disabled(!canPin(column, side: "right"))
              }.accessibilityIdentifier("pinTableColumn\(column)")
              HStack {
                Button("Move up") { move(column, delta: -1) }.frame(minHeight: 44).disabled(
                  draft.columnOrder.first == column)
                Button("Move down") { move(column, delta: 1) }.frame(minHeight: 44).disabled(
                  draft.columnOrder.last == column)
              }.font(.body).frame(minHeight: 44)
            }.padding(.vertical, 6)
          }
          Button("Reset columns") {
            draft = BookTableLayout.normalized(BookTableLayout.defaults, customFields: customFields)
          }.font(.body).frame(
            minHeight: 44)
        }.foregroundStyle(Color(uiColor: .label))
        HStack {
          Button("Cancel", action: dismiss.callAsFunction).frame(minHeight: 44)
          Spacer()
          Button("Apply columns") {
            layout = BookTableLayout.normalized(draft, customFields: customFields)
            density = draftDensity
            dismiss()
          }
          .accessibilityIdentifier("applyTableColumns")
          .frame(minHeight: 44)
        }.font(.body).buttonStyle(.plain).foregroundStyle(Color(uiColor: .label)).frame(
          minHeight: 44
        ).padding()
      }.navigationTitle("Table columns")
    }
  }

  private func move(_ column: String, delta: Int) {
    guard let index = draft.columnOrder.firstIndex(of: column),
      draft.columnOrder.indices.contains(index + delta)
    else { return }
    draft.columnOrder.swapAt(index, index + delta)
  }

  private func canPin(_ column: String, side: String) -> Bool {
    BookTableLayout.pinSide(column, layout: draft) == side
      || draft.columnOrder.filter { BookTableLayout.pinSide($0, layout: draft) == side }.count < 3
  }

  private func setPin(_ column: String, side: String) {
    guard side == "none" || canPin(column, side: side) else { return }
    var pins = draft.pinnedColumns ?? [:]
    pins.updateValue(side == "none" ? nil : side, forKey: column)
    draft.pinnedColumns = pins
  }

  private func fit(_ column: String) {
    guard BookTableLayout.isResizable(column) else { return }
    draft.columnWidths[column] = min(
      800, max(BookTableLayout.minimumWidth(column), fitWidth(column)))
  }

  private func fitAll() { for column in draft.columnOrder { fit(column) } }
}
