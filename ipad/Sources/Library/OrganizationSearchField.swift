import SwiftUI
import UIKit

struct OrganizationSearchField: UIViewRepresentable {
  @Binding var text: String
  let prompt: String
  let submit: () -> Void

  func makeUIView(context: Context) -> UISearchTextField {
    let field = UISearchTextField()
    field.adjustsFontForContentSizeCategory = true
    field.textColor = .label
    field.backgroundColor = .secondarySystemBackground
    field.returnKeyType = .search
    field.clearButtonMode = .whileEditing
    field.delegate = context.coordinator
    field.addTarget(
      context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
    field.setContentCompressionResistancePriority(.required, for: .vertical)
    field.accessibilityIdentifier = "organizationSearch"
    return field
  }

  func updateUIView(_ field: UISearchTextField, context: Context) {
    context.coordinator.parent = self
    if field.text != text { field.text = text }
    let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: field.traitCollection)
    field.font = font
    field.attributedPlaceholder = NSAttributedString(
      string: prompt, attributes: [.foregroundColor: UIColor.label, .font: font])
    field.accessibilityLabel = prompt
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISearchTextField, context: Context)
    -> CGSize?
  {
    CGSize(width: proposal.width ?? 320, height: max(44, (uiView.font?.lineHeight ?? 20) + 24))
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
    var parent: OrganizationSearchField

    init(parent: OrganizationSearchField) { self.parent = parent }

    @objc func changed(_ field: UISearchTextField) { parent.text = field.text ?? "" }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      parent.text = textField.text ?? ""
      textField.resignFirstResponder()
      parent.submit()
      return true
    }
  }
}
