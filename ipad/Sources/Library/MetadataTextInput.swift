import SwiftUI
import UIKit

struct MetadataTextInput: UIViewRepresentable {
  @Binding var text: String
  let label: String
  let identifier: String

  func makeUIView(context: Context) -> UITextView {
    let view = MetadataEditableTextView()
    view.font = .preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.backgroundColor = .systemBackground
    view.textColor = .label
    view.isScrollEnabled = true
    view.delegate = context.coordinator
    view.accessibilityLabel = label
    view.accessibilityIdentifier = identifier
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    context.coordinator.text = $text
    if view.text != text { view.text = text }
    let enabled = context.environment.isEnabled
    if view.isEditable != enabled { view.isEditable = enabled }
    if view.isSelectable != enabled { view.isSelectable = enabled }
    if view.isUserInteractionEnabled != enabled { view.isUserInteractionEnabled = enabled }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    guard let width = proposal.width else { return nil }
    return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  @MainActor
  final class Coordinator: NSObject, UITextViewDelegate {
    var text: Binding<String>
    init(text: Binding<String>) { self.text = text }
    func textViewDidChange(_ view: UITextView) { text.wrappedValue = view.text }
  }
}

private final class MetadataEditableTextView: UITextView {
  private var editorHeight: CGFloat {
    (font ?? .preferredFont(forTextStyle: .body)).lineHeight * 4
      + textContainerInset.top + textContainerInset.bottom
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: editorHeight)
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    CGSize(width: size.width, height: editorHeight)
  }

  override var accessibilityTraits: UIAccessibilityTraits {
    get {
      var traits = super.accessibilityTraits
      if !isEditable { traits.insert(.notEnabled) }
      return traits
    }
    set { super.accessibilityTraits = newValue }
  }
}
