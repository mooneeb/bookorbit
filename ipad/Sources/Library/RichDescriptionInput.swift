import SwiftUI
import UIKit

struct RichDescriptionInput: UIViewRepresentable {
  @Binding var html: String
  let state: RichDescriptionEditingState
  let isPreview: Bool
  let isLocked: Bool

  func makeUIView(context: Context) -> RichDescriptionTextView {
    let view = RichDescriptionTextView(usingTextLayoutManager: false)
    view.backgroundColor = .systemBackground
    view.textColor = .label
    view.font = .preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.isScrollEnabled = true
    view.allowsEditingTextAttributes = false
    view.dataDetectorTypes = []
    view.linkTextAttributes = [.foregroundColor: UIColor.link, .underlineStyle: 1]
    view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
    view.delegate = context.coordinator
    view.typingAttributes = RichDescriptionHTML.attributes([:])
    context.coordinator.load(html, into: view)
    state.attach(view) { [weak coordinator = context.coordinator, weak view] in
      guard let view else { return }
      coordinator?.publish(view)
    }
    return view
  }

  func updateUIView(_ view: RichDescriptionTextView, context: Context) {
    let coordinator = context.coordinator
    coordinator.isApplyingDocument = true
    defer { coordinator.isApplyingDocument = false }
    coordinator.html = $html
    if coordinator.loadedHTML != html {
      coordinator.load(html, into: view, external: true)
    }
    let editable =
      context.environment.isEnabled && !isLocked && !isPreview && coordinator.isSupported
    if view.isEditable != editable {
      if !editable { view.resignFirstResponder() }
      view.isEditable = editable
    }
    view.isSelectable = context.environment.isEnabled && coordinator.isSupported
    view.isUserInteractionEnabled = context.environment.isEnabled
    view.isDescriptionPreview = isPreview
    view.accessibilityLabel = isPreview ? "Description preview" : "Description"
    view.accessibilityIdentifier = isPreview ? "metadataDescriptionPreview" : "metadataDescription"
    if coordinator.contentSizeCategory != view.traitCollection.preferredContentSizeCategory {
      coordinator.contentSizeCategory = view.traitCollection.preferredContentSizeCategory
      let selection = view.selectedRange
      let typing = RichDescriptionHTML.attributes(view.typingAttributes)
      let text = NSMutableAttributedString(attributedString: view.attributedText)
      RichDescriptionHTML.restyle(text)
      view.textStorage.setAttributedString(text)
      view.selectedRange = selection
      view.typingAttributes = typing
      view.rebuildDecorations()
      view.invalidateIntrinsicContentSize()
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: RichDescriptionTextView, context: Context)
    -> CGSize?
  {
    guard let width = proposal.width else { return nil }
    return CGSize(
      width: width, height: max(180, UIFont.preferredFont(forTextStyle: .body).lineHeight * 7 + 24))
  }

  func makeCoordinator() -> Coordinator { Coordinator(html: $html, state: state) }

  static func dismantleUIView(_ view: RichDescriptionTextView, coordinator: Coordinator) {
    view.resignFirstResponder()
    view.undoManager?.removeAllActions()
    view.delegate = nil
    coordinator.state.detach(view)
  }

  @MainActor
  final class Coordinator: NSObject, UITextViewDelegate {
    var html: Binding<String>
    let state: RichDescriptionEditingState
    var loadedHTML = ""
    var isSupported = true
    var contentSizeCategory: UIContentSizeCategory?
    var isApplyingDocument = false
    private var loadGeneration = UUID()

    init(html: Binding<String>, state: RichDescriptionEditingState) {
      self.html = html
      self.state = state
    }

    func load(_ value: String, into view: RichDescriptionTextView, external: Bool = false) {
      let wasApplyingDocument = isApplyingDocument
      isApplyingDocument = true
      defer { isApplyingDocument = wasApplyingDocument }
      let generation = UUID()
      loadGeneration = generation
      loadedHTML = value
      view.undoManager?.removeAllActions()
      if let text = RichDescriptionHTML.decode(value) {
        view.attributedText = text
        isSupported = true
      } else {
        view.attributedText = NSAttributedString(string: "")
        isSupported = false
      }
      view.selectedRange = NSRange(location: 0, length: 0)
      let semantic =
        view.attributedText.length > 0
        ? view.attributedText.attributes(at: 0, effectiveRange: nil) : [:]
      view.typingAttributes = RichDescriptionHTML.attributes(semantic)
      view.rebuildDecorations()
      Task { @MainActor [weak self, weak view] in
        guard let self, let view, self.loadGeneration == generation, view.delegate === self else {
          return
        }
        self.state.setSupported(self.isSupported)
        self.state.message =
          self.isSupported
          ? nil
          : "This description is too large or deeply nested to edit here. Its saved content is kept."
        if external { self.state.loadedExternalContent() }
        self.state.refresh()
      }
    }

    func publish(_ view: RichDescriptionTextView) {
      guard isSupported, !isApplyingDocument else { return }
      let value = RichDescriptionHTML.encode(view.attributedText)
      guard value.utf8.count <= RichDescriptionHTML.maximumHTMLBytes else { return }
      loadedHTML = value
      html.wrappedValue = value
      state.message = nil
      state.refresh()
    }

    func textViewDidChange(_ textView: UITextView) {
      guard let view = textView as? RichDescriptionTextView else { return }
      publish(view)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      if !isApplyingDocument { state.refresh() }
    }

    func textView(
      _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
      guard isSupported, textView.isEditable else { return false }
      guard
        text.utf16.count <= RichDescriptionHTML.maximumTextLength
          - (textView.attributedText.length - range.length)
      else {
        state.message = "This description is too large. Shorten it before adding more text."
        return false
      }
      let next = NSMutableAttributedString(attributedString: textView.attributedText)
      next.replaceCharacters(
        in: range, with: NSAttributedString(string: text, attributes: textView.typingAttributes))
      guard next.length <= RichDescriptionHTML.maximumTextLength,
        RichDescriptionHTML.paragraphRanges(next.string).count <= 4096,
        RichDescriptionHTML.encode(next).utf8.count <= RichDescriptionHTML.maximumHTMLBytes
      else {
        state.message = "This description is too large. Shorten it before adding more text."
        return false
      }
      if text == "\n" {
        var path = textView.typingAttributes[.descriptionPath] as? [String] ?? []
        if let item = path.lastIndex(where: { $0.hasPrefix("li:") }) {
          let paragraph = RichDescriptionHTML.paragraphRanges(textView.text).first {
            range.location >= $0.location && range.location <= NSMaxRange($0)
          }
          if paragraph?.length == 0 {
            if let list = path[..<item].lastIndex(where: { $0 == "ul" || $0 == "ol" }) {
              path.removeSubrange(list...)
            }
          } else {
            path[item] = "li:\(UUID().uuidString)"
          }
          textView.typingAttributes[.descriptionPath] = path
          textView.typingAttributes = RichDescriptionHTML.attributes(textView.typingAttributes)
        }
      }
      return true
    }

    func textView(
      _ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction
    ) -> UIAction? { nil }

    func textView(
      _ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? { nil }
  }
}

final class RichDescriptionTextView: UITextView {
  var isDescriptionPreview = false
  private let editingUndoManager = UndoManager()
  private var decorations: [(range: NSRange, path: [String], ordinal: Int, showsMarker: Bool)] = []

  override var undoManager: UndoManager? { editingUndoManager }

  override func paste(_ sender: Any?) {
    guard isEditable, let text = UIPasteboard.general.string else { return }
    insertText(
      text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
  }

  func rebuildDecorations() {
    var ordinals: [String: Int] = [:]
    var itemNumbers: [String: Int] = [:]
    decorations = RichDescriptionHTML.paragraphRanges(text).map { range in
      let path = RichDescriptionHTML.path(in: attributedText, at: range.location)
      var ordinal = 0
      var showsMarker = false
      if let item = path.lastIndex(where: { $0.hasPrefix("li:") }) {
        let key = path[item]
        if let number = itemNumbers[key] {
          ordinal = number
        } else {
          showsMarker = true
          let parent = path.prefix(item).joined(separator: "/")
          ordinal = (ordinals[parent] ?? 0) + 1
          ordinals[parent] = ordinal
          itemNumbers[key] = ordinal
        }
      }
      return (range, path, ordinal, showsMarker)
    }
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    super.draw(rect)
    guard let context = UIGraphicsGetCurrentContext(), !decorations.isEmpty else { return }
    let visible = layoutManager.glyphRange(
      forBoundingRect: bounds.offsetBy(dx: -textContainerInset.left, dy: -textContainerInset.top),
      in: textContainer)
    let characters = layoutManager.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
    let font = UIFont.preferredFont(forTextStyle: .body)
    for decoration in decorations {
      if decoration.range.location > NSMaxRange(characters) { break }
      guard NSMaxRange(decoration.range) >= characters.location, decoration.range.length > 0 else {
        continue
      }
      let glyph = layoutManager.glyphRange(
        forCharacterRange: NSRange(location: decoration.range.location, length: 1),
        actualCharacterRange: nil)
      let line = layoutManager.lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
      let origin = CGPoint(
        x: textContainerInset.left + textContainer.lineFragmentPadding,
        y: line.minY + textContainerInset.top)
      let lists = decoration.path.filter { $0 == "ul" || $0 == "ol" }
      let quotes = decoration.path.filter { $0 == "blockquote" }.count
      if let kind = lists.last, decoration.showsMarker {
        let marker = kind == "ol" ? "\(decoration.ordinal)." : "•"
        let attributes: [NSAttributedString.Key: Any] = [
          .font: font, .foregroundColor: UIColor.label,
        ]
        let width = (marker as NSString).size(withAttributes: attributes).width
        let x = origin.x + CGFloat(lists.count + quotes) * font.lineHeight - width - 6
        (marker as NSString).draw(at: CGPoint(x: x, y: origin.y), withAttributes: attributes)
      }
      if quotes > 0 {
        context.setStrokeColor(UIColor.separator.cgColor)
        context.setLineWidth(2)
        for depth in 0..<quotes {
          let x = origin.x + CGFloat(depth) * font.lineHeight + 2
          context.move(to: CGPoint(x: x, y: origin.y))
          context.addLine(to: CGPoint(x: x, y: origin.y + line.height))
        }
        context.strokePath()
      }
    }
  }

  override var accessibilityTraits: UIAccessibilityTraits {
    get {
      var traits = super.accessibilityTraits
      if !isEditable && !isDescriptionPreview { traits.insert(.notEnabled) }
      return traits
    }
    set { super.accessibilityTraits = newValue }
  }

  override var accessibilityValue: String? {
    get {
      guard isDescriptionPreview else { return super.accessibilityValue }
      return decorations.map { decoration in
        let quote = decoration.path.contains("blockquote") ? "Quote: " : ""
        let numbered = decoration.path.last(where: { $0 == "ul" || $0 == "ol" }) == "ol"
        let marker =
          decoration.showsMarker ? (numbered ? "\(decoration.ordinal). " : "Bullet: ") : ""
        return quote + marker
          + (text as NSString).substring(with: decoration.range)
          .replacingOccurrences(of: "\u{2028}", with: "\n")
      }.joined(separator: "\n")
    }
    set { super.accessibilityValue = newValue }
  }
}
