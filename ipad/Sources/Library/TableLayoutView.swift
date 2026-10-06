import SwiftUI

struct TableLayoutView: View {
  @Binding var layout: TableLayoutState
  @Environment(\.dismiss) private var dismiss
  @State private var draft: TableLayoutState

  init(layout: Binding<TableLayoutState>) {
    _layout = layout
    _draft = State(initialValue: BookTableLayout.normalized(layout.wrappedValue))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        List {
          ForEach(draft.columnOrder, id: \.self) { column in
            VStack(alignment: .leading, spacing: 10) {
              Toggle(
                queryFieldLabel(column),
                isOn: Binding(
                  get: { !draft.hiddenColumns.contains(column) },
                  set: { visible in
                    if visible {
                      draft.hiddenColumns.removeAll { $0 == column }
                    } else if BookTableLayout.visible(draft).count > 1 {
                      draft.hiddenColumns.append(column)
                    }
                  }))
              Stepper(
                "Width: \(Int(draft.columnWidths[column] ?? 180)) points",
                value: Binding(
                  get: { draft.columnWidths[column] ?? 180 },
                  set: { draft.columnWidths[column] = $0 }), in: 120...600, step: 20
              )
              .disabled(draft.hiddenColumns.contains(column))
              HStack {
                Button("Move up") { move(column, delta: -1) }.frame(minHeight: 44).disabled(
                  draft.columnOrder.first == column)
                Button("Move down") { move(column, delta: 1) }.frame(minHeight: 44).disabled(
                  draft.columnOrder.last == column)
              }.font(.body).frame(minHeight: 44)
            }.padding(.vertical, 6)
          }
          Button("Reset columns") { draft = BookTableLayout.defaults }.font(.body).frame(
            minHeight: 44)
        }.foregroundStyle(Color(uiColor: .label))
        HStack {
          Button("Cancel", action: dismiss.callAsFunction).frame(minHeight: 44)
          Spacer()
          Button("Apply columns") {
            layout = BookTableLayout.normalized(draft)
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
}
