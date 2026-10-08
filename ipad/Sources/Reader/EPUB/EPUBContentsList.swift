import SwiftUI

struct EPUBContentsList: View {
  let outline: EPUBContentsOutlineModel
  let canNavigate: Bool
  let open: (EPUBContentsEntry) -> Void

  var body: some View {
    List {
      ForEach(outline.visibleEntries) { entry in
        HStack(spacing: 0) {
          if entry.hasChildren {
            Button {
              outline.toggle(entry)
            } label: {
              Image(
                systemName: outline.collapsed.contains(entry.id) ? "chevron.right" : "chevron.down"
              )
              .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(
              "\(outline.collapsed.contains(entry.id) ? "Expand" : "Collapse") \(entry.label)"
            )
            .accessibilityIdentifier("epubContentsExpand\(entry.id)")
          }
          if entry.href != nil || entry.chapter != nil {
            Button {
              open(entry)
            } label: {
              Text(entry.label.isEmpty ? "Untitled section" : entry.label)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .disabled(!canNavigate)
            .accessibilityIdentifier("epubContentsEntry\(entry.id)")
            .accessibilityHint("Contents level \(entry.depth + 1)")
          } else {
            Text(entry.label.isEmpty ? "Untitled section" : entry.label).font(.headline)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          }
        }
        .padding(.leading, CGFloat(min(entry.depth, 4)) * 12)
        .accessibilityElement(children: .contain)
      }
      if outline.isTruncated {
        Text(
          "This outline is limited to 4,096 entries and 33 levels. Use Go to position or Search book to reach other passages."
        )
        .font(.caption).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("epubContentsLimit")
      }
      if outline.entries.isEmpty { Text("No contents available.") }
    }
    .listStyle(.plain).buttonStyle(.plain)
  }
}
