import SwiftUI
import UIKit

struct RichDescriptionReadOnlyView: UIViewRepresentable {
  let html: String

  func makeUIView(context: Context) -> RichDescriptionTextView {
    let view = RichDescriptionTextView(usingTextLayoutManager: false)
    view.backgroundColor = .clear
    view.isEditable = false
    view.isSelectable = true
    view.isScrollEnabled = false
    view.isDescriptionPreview = true
    view.adjustsFontForContentSizeCategory = true
    view.dataDetectorTypes = []
    view.linkTextAttributes = [.foregroundColor: UIColor.link, .underlineStyle: 1]
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.accessibilityLabel = "Description"
    view.accessibilityIdentifier = "bookDescription"
    return view
  }

  func updateUIView(_ view: RichDescriptionTextView, context: Context) {
    let coordinator = context.coordinator
    let category = view.traitCollection.preferredContentSizeCategory
    guard coordinator.loadedHTML != html || coordinator.contentSizeCategory != category else {
      return
    }
    coordinator.loadedHTML = html
    coordinator.contentSizeCategory = category
    let text = NSMutableAttributedString(
      attributedString: RichDescriptionHTML.decode(html)
        ?? NSAttributedString(
          string: "This description is too large or deeply nested to display here.",
          attributes: RichDescriptionHTML.attributes([:])))
    text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) {
      value, range, _ in
      if let url = value as? URL, RichDescriptionHTML.allowedURL(url.absoluteString) == nil {
        text.removeAttribute(.link, range: range)
      }
    }
    view.attributedText = text
    view.rebuildDecorations()
    view.invalidateIntrinsicContentSize()
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: RichDescriptionTextView, context: Context)
    -> CGSize?
  {
    guard let width = proposal.width, width > 0 else { return nil }
    return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var loadedHTML: String?
    var contentSizeCategory: UIContentSizeCategory?
  }
}
