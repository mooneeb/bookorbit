import PDFKit
import SwiftUI

struct PDFContentsView: View {
  @State private var model: PDFContentsModel
  let onSelect: (Int) -> Void
  @Environment(\.dismiss) private var dismiss

  init(document: PDFDocument, onSelect: @escaping (Int) -> Void) {
    _model = State(initialValue: PDFContentsModel(document: document))
    self.onSelect = onSelect
  }

  var body: some View {
    NavigationStack {
      List {
        if let title = model.sectionTitle {
          Text(title).font(.headline).accessibilityAddTraits(.isHeader)
        }
        if let error = model.error { Text(error) }
        if model.entries.isEmpty {
          ContentUnavailableView {
            Label("No contents", systemImage: "list.bullet")
          } description: {
            Text("This PDF has no sections to open.").foregroundStyle(.primary)
          }
        }
        ForEach(model.entries) { entry in
          HStack {
            Button {
              if let page = entry.pageIndex {
                onSelect(page)
                dismiss()
              } else {
                model.openChildren(entry)
              }
            } label: {
              VStack(alignment: .leading) {
                Text(entry.title)
                if let page = entry.pageIndex {
                  Text("Page \(page + 1)")
                } else if entry.hasChildren {
                  Text("\(entry.outline.numberOfChildren) sections")
                } else {
                  Text("Page unavailable")
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 8)
              .contentShape(Rectangle())
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pdfOutline\(entry.id)")
            .disabled(entry.pageIndex == nil && !entry.hasChildren)
            if entry.pageIndex != nil && entry.hasChildren {
              Button {
                model.openChildren(entry)
              } label: {
                Image(systemName: "chevron.right")
                  .frame(minWidth: 44, minHeight: 44)
                  .contentShape(Rectangle())
              }
              .accessibilityLabel("View sections in \(entry.title)")
            }
          }
        }
      }
      .buttonStyle(.plain)
      .foregroundStyle(.primary)
      .navigationTitle("PDF contents")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        VStack {
          if model.canGoPrevious || model.canGoNext {
            HStack {
              Button("Previous sections", action: model.previousSections)
                .disabled(!model.canGoPrevious)
              Spacer()
              Button("Next sections", action: model.nextSections)
                .disabled(!model.canGoNext)
            }
          }
          HStack {
            if model.canGoBack {
              Button("Back to contents", action: model.goBack)
                .accessibilityIdentifier("pdfContentsBack")
            }
            Spacer()
            Button("Cancel", action: dismiss.callAsFunction)
          }
        }
        .buttonStyle(PDFContentsActionStyle())
        .font(.body)
        .padding(.horizontal)
        .background(.background)
      }
    }
  }
}

private struct PDFContentsActionStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(Color(uiColor: .label))
      .padding(.vertical, 10)
      .frame(minHeight: 44)
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}
