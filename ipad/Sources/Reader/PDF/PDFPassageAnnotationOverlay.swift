import PDFKit
import UIKit

@MainActor
final class PDFPassageAnnotationOverlay: UIView {
  private var targets: [UIButton] = []
  private var highlights: [CAShapeLayer] = []

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    targets.contains { !$0.isHidden && $0.frame.contains(point) }
  }

  private func color(_ value: String) -> UIColor {
    let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
    guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return .systemYellow }
    return UIColor(
      red: CGFloat((rgb >> 16) & 255) / 255,
      green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
  }

  func update(
    items: [NativeAnnotationItem], frameForRect: (AnnotationRect) -> CGRect,
    open: @escaping (NativeAnnotationItem) -> Void
  ) {
    for target in targets { target.removeFromSuperview() }
    for highlight in highlights { highlight.removeFromSuperlayer() }
    targets = []
    highlights = []
    for item in items {
      guard let position = item.pdf else { continue }
      let rects = position.rects.isEmpty ? [position.rect] : position.rects
      for rect in rects.prefix(max(0, 1000 - highlights.count)) {
        let layer = CAShapeLayer()
        layer.path = UIBezierPath(rect: frameForRect(rect)).cgPath
        layer.fillColor = color(item.color).withAlphaComponent(0.25).cgColor
        self.layer.addSublayer(layer)
        highlights.append(layer)
      }
      let button = UIButton(type: .custom)
      var frame = frameForRect(position.rect)
      frame.size.width = max(44, frame.width)
      frame.size.height = max(44, frame.height)
      button.frame = frame
      button.accessibilityLabel =
        "\(item.kind == "handwriting" ? "Handwritten passage note" : item.kind == "text_note" ? "Passage text note" : "Passage highlight"): \(item.text)"
      button.accessibilityIdentifier = "pdfPrivateAnnotation\(item.id)"
      button.addAction(UIAction { _ in open(item) }, for: .touchUpInside)
      addSubview(button)
      targets.append(button)
    }
  }
}
