import SwiftUI

private struct EPUBContentsEntry: Identifiable {
  let id: Int
  let label: String
  let href: String?
  let depth: Int
}

struct EPUBContentsView: View {
  let model: EPUBReaderModel
  @Environment(\.dismiss) private var dismiss

  private var entries: [EPUBContentsEntry] {
    var pending = model.contents.reversed().map { ($0, 0) }
    var entries: [EPUBContentsEntry] = []
    while let (item, depth) = pending.popLast(), entries.count < 4096 {
      entries.append(
        .init(
          id: entries.count, label: String(item.label.prefix(500)), href: item.href, depth: depth))
      if depth < 32 {
        for child in (item.children ?? []).reversed() { pending.append((child, depth + 1)) }
      }
      if pending.count > 4096 { break }
    }
    return entries
  }

  var body: some View {
    NavigationStack {
      List {
        if !entries.isEmpty {
          ForEach(entries) { entry in
            if let href = entry.href {
              Button {
                open(href)
              } label: {
                Text(entry.label).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                  .padding(.leading, CGFloat(min(entry.depth, 4)) * 12)
              }.accessibilityIdentifier("epubContentsEntry\(entry.id)")
                .disabled(!model.canNavigate)
            } else {
              Text(entry.label).font(.headline)
            }
          }
        } else {
          ForEach(0..<model.chapterCount, id: \.self) { index in
            Button("Chapter \(index + 1)") {
              Task {
                await model.goToChapter(index)
                if model.error == nil { dismiss() }
              }
            }.frame(minHeight: 44).disabled(!model.canNavigate)
          }
        }
        if let error = model.error { Text(error).accessibilityIdentifier("epubContentsError") }
      }
      .buttonStyle(.plain).navigationTitle("Contents")
      .toolbar { Button("Done", action: dismiss.callAsFunction).disabled(model.isNavigating) }
    }
    .interactiveDismissDisabled(model.isNavigating)
  }

  private func open(_ href: String) {
    Task {
      await model.goToHref(href)
      if model.error == nil { dismiss() }
    }
  }
}
