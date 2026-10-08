import Foundation
import Observation

struct EPUBContentsEntry: Identifiable {
  let id: Int
  let label: String
  let href: String?
  let chapter: Int?
  let depth: Int
  let hasChildren: Bool
}

@MainActor @Observable
final class EPUBContentsOutlineModel {
  private(set) var entries: [EPUBContentsEntry] = []
  private(set) var isTruncated = false
  private(set) var collapsed: Set<Int> = []

  var visibleEntries: [EPUBContentsEntry] {
    var hiddenBelow: Int?
    return entries.filter { entry in
      if let depth = hiddenBelow {
        if entry.depth > depth { return false }
        hiddenBelow = nil
      }
      if collapsed.contains(entry.id) { hiddenBelow = entry.depth }
      return true
    }
  }

  func rebuild(contents: [EpubTocItem], chapterCount: Int) {
    entries = []
    collapsed = []
    isTruncated = false
    if contents.isEmpty {
      entries = (0..<min(chapterCount, 4096)).map {
        EPUBContentsEntry(
          id: $0, label: "Chapter \($0 + 1)", href: nil, chapter: $0, depth: 0,
          hasChildren: false)
      }
      isTruncated = chapterCount > 4096
      return
    }
    // A depth-first cursor bounds pending work even when a publisher supplies a wide tree.
    var pending: [(items: [EpubTocItem], index: Int, depth: Int)] = [(contents, 0, 0)]
    while !pending.isEmpty, entries.count < 4096 {
      let frame = pending.removeLast()
      guard frame.index < frame.items.count else { continue }
      let item = frame.items[frame.index]
      pending.append((frame.items, frame.index + 1, frame.depth))
      let children = item.children ?? []
      let canExpand = !children.isEmpty && frame.depth < 32
      entries.append(
        EPUBContentsEntry(
          id: entries.count, label: String(item.label.prefix(500)), href: item.href,
          chapter: nil, depth: frame.depth, hasChildren: canExpand))
      if canExpand {
        pending.append((children, 0, frame.depth + 1))
      } else if !children.isEmpty {
        isTruncated = true
      }
    }
    if pending.contains(where: { $0.index < $0.items.count }) { isTruncated = true }
  }

  func toggle(_ entry: EPUBContentsEntry) {
    guard entry.hasChildren else { return }
    if collapsed.contains(entry.id) {
      collapsed.remove(entry.id)
    } else {
      collapsed.insert(entry.id)
    }
  }
}
