import Observation
import UIKit

@MainActor @Observable
final class RichDescriptionEditingState {
  private(set) var activeMarks: Set<String> = []
  private(set) var canUndo = false
  private(set) var canRedo = false
  private(set) var canIndent = false
  private(set) var canOutdent = false
  private(set) var hasLink = false
  private(set) var link = ""
  private(set) var contentRevision = 0
  private(set) var isSupported = true
  var message: String?
  @ObservationIgnored private weak var editor: RichDescriptionTextView?
  @ObservationIgnored private var changed: (() -> Void)?

  func attach(_ editor: RichDescriptionTextView, changed: @escaping () -> Void) {
    self.editor = editor
    self.changed = changed
    editor.undoManager?.levelsOfUndo = 50
  }

  func detach(_ editor: RichDescriptionTextView) {
    guard self.editor === editor else { return }
    self.editor = nil
    changed = nil
  }

  func loadedExternalContent() { contentRevision += 1 }
  func setSupported(_ supported: Bool) { isSupported = supported }

  func refresh() {
    guard let editor else { return }
    let attributes = selectionAttributes(editor)
    activeMarks = Set(
      RichDescriptionHTML.marks.compactMap { key, name in
        attributes[key] as? Bool == true ? name : nil
      })
    let path = attributes[.descriptionPath] as? [String] ?? []
    if path.contains("ul") { activeMarks.insert("ul") }
    if path.contains("ol") { activeMarks.insert("ol") }
    if path.contains("blockquote") { activeMarks.insert("blockquote") }
    canOutdent = path.contains { $0 == "ul" || $0 == "ol" }
    let ranges = selectedParagraphs(editor)
    let all = RichDescriptionHTML.paragraphRanges(editor.text)
    if let first = ranges.first, let index = all.firstIndex(of: first), index > 0,
      let item = path.lastIndex(where: { $0.hasPrefix("li:") })
    {
      let previous = RichDescriptionHTML.path(
        in: editor.attributedText, at: all[index - 1].location)
      canIndent =
        path.count + 2 <= RichDescriptionHTML.maximumDepth
        && previous.count >= item + 1
        && Array(previous.prefix(item)) == Array(path.prefix(item))
        && previous[item] != path[item]
    } else {
      canIndent = false
    }
    link = (attributes[.link] as? URL)?.absoluteString ?? ""
    hasLink = !link.isEmpty
    canUndo = editor.undoManager?.canUndo == true
    canRedo = editor.undoManager?.canRedo == true
    editor.rebuildDecorations()
  }

  func toggleMark(_ name: String) {
    guard let (key, _) = RichDescriptionHTML.marks.first(where: { $0.1 == name }) else { return }
    let enabled = !activeMarks.contains(name)
    mutate { editor, text in
      if editor.selectedRange.length > 0 {
        text.addAttribute(key, value: enabled, range: editor.selectedRange)
      }
      editor.typingAttributes[key] = enabled
    }
  }

  func toggleList(_ kind: String) {
    let remove = activeMarks.contains(kind)
    let selectedPath =
      editor.map { selectionAttributes($0)[.descriptionPath] as? [String] ?? [] } ?? []
    let selectedList = selectedPath.lastIndex(where: { $0 == "ul" || $0 == "ol" })
    changeParagraphs(expandItems: true) { path in
      if let index = selectedList, path.count > index + 1 {
        if remove { return self.lift(path, list: index) }
        var next = path
        next[index] = kind
        return next
      }
      return path + [kind, "li:\(UUID().uuidString)"]
    }
  }

  func toggleQuote() {
    let remove = activeMarks.contains("blockquote")
    changeParagraphs { path in
      if remove { return path.filter { $0 != "blockquote" } }
      return path.count < RichDescriptionHTML.maximumDepth ? path + ["blockquote"] : path
    }
  }

  func indent() {
    guard canIndent, let editor, let first = selectedParagraphs(editor).first else { return }
    let all = RichDescriptionHTML.paragraphRanges(editor.text)
    guard let index = all.firstIndex(of: first), index > 0 else { return }
    let previous = RichDescriptionHTML.path(in: editor.attributedText, at: all[index - 1].location)
    let current = RichDescriptionHTML.path(in: editor.attributedText, at: first.location)
    guard let item = current.lastIndex(where: { $0.hasPrefix("li:") }), previous.count > item else {
      return
    }
    let parent = Array(previous.prefix(item + 1))
    guard let list = current.lastIndex(where: { $0 == "ul" || $0 == "ol" }) else { return }
    changeParagraphs(expandItems: true) { path in
      guard list + 1 < path.count else { return path }
      return parent + Array(path.suffix(from: list))
    }
  }

  func outdent() {
    guard canOutdent, let editor,
      let path = selectionAttributes(editor)[.descriptionPath] as? [String],
      let list = path.lastIndex(where: { $0 == "ul" || $0 == "ol" })
    else { return }
    changeParagraphs(expandItems: true) { self.lift($0, list: list) }
  }

  func applyLink(_ url: URL?) {
    mutate { editor, text in
      let range = self.linkRange(editor)
      if range.length > 0 {
        if let url {
          text.addAttribute(.link, value: url, range: range)
        } else {
          text.removeAttribute(.link, range: range)
        }
      }
      editor.typingAttributes[.link] = url
    }
  }

  func clearFormatting() {
    mutate { editor, text in
      let selected = editor.selectedRange
      if selected.length > 0 {
        for (key, _) in RichDescriptionHTML.marks { text.removeAttribute(key, range: selected) }
        text.removeAttribute(.link, range: selected)
      }
      for range in self.selectedParagraphs(editor) {
        let full = self.fullParagraphRange(range, in: text)
        if full.length > 0 { text.removeAttribute(.descriptionPath, range: full) }
      }
      editor.typingAttributes = RichDescriptionHTML.attributes([:])
    }
  }

  func undo() {
    guard let editor, editor.isEditable else { return }
    editor.becomeFirstResponder()
    editor.undoManager?.undo()
    refresh()
  }

  func redo() {
    guard let editor, editor.isEditable else { return }
    editor.becomeFirstResponder()
    editor.undoManager?.redo()
    refresh()
  }

  func prepareLink() {
    editor?.resignFirstResponder()
    refresh()
  }
  func endEditing() { editor?.resignFirstResponder() }

  private func changeParagraphs(expandItems: Bool = false, _ transform: ([String]) -> [String]) {
    mutate { editor, text in
      let selected = self.selectedParagraphs(editor)
      let prefixes = selected.compactMap { range -> [String]? in
        let path = RichDescriptionHTML.path(in: text, at: range.location)
        guard let item = path.lastIndex(where: { $0.hasPrefix("li:") }) else { return nil }
        return Array(path.prefix(item + 1))
      }
      let ranges =
        expandItems
        ? RichDescriptionHTML.paragraphRanges(editor.text).filter { range in
          let path = RichDescriptionHTML.path(in: text, at: range.location)
          return selected.contains(range)
            || prefixes.contains { Array(path.prefix($0.count)) == $0 }
        } : selected
      for range in ranges {
        let path = RichDescriptionHTML.path(in: text, at: range.location)
        let next = transform(path)
        let full = self.fullParagraphRange(range, in: text)
        if full.length > 0 { text.addAttribute(.descriptionPath, value: next, range: full) }
        if NSLocationInRange(editor.selectedRange.location, full) || full.length == 0 {
          editor.typingAttributes[.descriptionPath] = next
        }
      }
    }
  }

  private func lift(_ path: [String], list: Int) -> [String] {
    guard path.count > list + 1 else { return path }
    let outer = Array(path.prefix(list))
    guard let outerItem = outer.lastIndex(where: { $0.hasPrefix("li:") }) else {
      return outer + Array(path.dropFirst(list + 2))
    }
    return Array(outer.prefix(outerItem)) + [path[list + 1]] + Array(path.dropFirst(list + 2))
  }

  private func mutate(_ action: (RichDescriptionTextView, NSMutableAttributedString) -> Void) {
    guard let editor, editor.isEditable else { return }
    editor.becomeFirstResponder()
    let old = Snapshot(editor)
    let text = NSMutableAttributedString(attributedString: editor.attributedText)
    action(editor, text)
    RichDescriptionHTML.restyle(text)
    guard RichDescriptionHTML.encode(text).utf8.count <= RichDescriptionHTML.maximumHTMLBytes else {
      editor.typingAttributes = old.typing
      message = "This description is too large to format. Shorten it before adding formatting."
      return
    }
    let typing = RichDescriptionHTML.attributes(editor.typingAttributes)
    let textChanged = !text.isEqual(to: old.text)
    if textChanged {
      editor.textStorage.setAttributedString(text)
      editor.selectedRange = old.selection
    }
    editor.typingAttributes = typing
    editor.undoManager?.registerUndo(withTarget: self) { target in target.restore(old) }
    if textChanged { changed?() }
    refresh()
  }

  private func restore(_ snapshot: Snapshot) {
    guard let editor, editor.isEditable else { return }
    let inverse = Snapshot(editor)
    let textChanged = !snapshot.text.isEqual(to: inverse.text)
    if textChanged { editor.textStorage.setAttributedString(snapshot.text) }
    editor.selectedRange = snapshot.selection
    editor.typingAttributes = snapshot.typing
    editor.undoManager?.registerUndo(withTarget: self) { target in target.restore(inverse) }
    if textChanged { changed?() }
    refresh()
  }

  private func selectionAttributes(_ editor: RichDescriptionTextView) -> [NSAttributedString.Key:
    Any]
  {
    if editor.selectedRange.length == 0 { return editor.typingAttributes }
    var common = editor.attributedText.attributes(
      at: editor.selectedRange.location, effectiveRange: nil)
    editor.attributedText.enumerateAttributes(in: editor.selectedRange) { attributes, _, _ in
      for (key, _) in RichDescriptionHTML.marks where attributes[key] as? Bool != true {
        common[key] = nil
      }
      if (attributes[.link] as? URL) != (common[.link] as? URL) { common[.link] = nil }
    }
    return common
  }

  private func linkRange(_ editor: RichDescriptionTextView) -> NSRange {
    if editor.selectedRange.length > 0 { return editor.selectedRange }
    guard editor.attributedText.length > 0 else { return editor.selectedRange }
    var range = NSRange()
    let index = min(editor.selectedRange.location, editor.attributedText.length - 1)
    if editor.attributedText.attribute(.link, at: index, effectiveRange: &range) != nil {
      return range
    }
    return editor.selectedRange
  }

  private func selectedParagraphs(_ editor: RichDescriptionTextView) -> [NSRange] {
    let selection = editor.selectedRange
    return RichDescriptionHTML.paragraphRanges(editor.text).filter { range in
      if selection.length == 0 {
        return selection.location >= range.location && selection.location <= NSMaxRange(range)
      }
      return range.location < NSMaxRange(selection) && NSMaxRange(range) >= selection.location
    }
  }

  private func fullParagraphRange(_ range: NSRange, in text: NSAttributedString) -> NSRange {
    NSRange(
      location: range.location, length: range.length + (NSMaxRange(range) < text.length ? 1 : 0))
  }

  private struct Snapshot {
    let text: NSAttributedString
    let selection: NSRange
    let typing: [NSAttributedString.Key: Any]
    @MainActor
    init(_ editor: RichDescriptionTextView) {
      text = NSAttributedString(attributedString: editor.attributedText)
      selection = editor.selectedRange
      typing = editor.typingAttributes
    }
  }
}
