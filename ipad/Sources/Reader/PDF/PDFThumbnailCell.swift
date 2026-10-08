import UIKit

@MainActor
final class PDFThumbnailCell: UICollectionViewCell {
  static let reuseIdentifier = "PDFThumbnailCell"
  private let preview = UIImageView()
  private let pageLabel = UILabel()
  private let previewStatus = UILabel()
  private(set) var pageIndex: Int?
  private(set) var requestID = UUID()
  private var isCurrentPage = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    preview.contentMode = .scaleAspectFit
    preview.backgroundColor = .tertiarySystemBackground
    preview.layer.cornerRadius = 8
    preview.clipsToBounds = true
    preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    pageLabel.textAlignment = .center
    pageLabel.numberOfLines = 0
    pageLabel.adjustsFontForContentSizeCategory = true
    pageLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    previewStatus.textAlignment = .center
    previewStatus.numberOfLines = 0
    previewStatus.adjustsFontForContentSizeCategory = true
    previewStatus.setContentCompressionResistancePriority(.required, for: .vertical)
    let stack = UIStackView(arrangedSubviews: [preview, pageLabel, previewStatus])
    stack.axis = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
      preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
    ])
    contentView.layer.cornerRadius = 12
    isAccessibilityElement = true
    registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) {
      (cell: PDFThumbnailCell, _: UITraitCollection) in
      cell.contentView.layer.borderColor =
        (cell.isCurrentPage ? UIColor.label : UIColor.separator).cgColor
    }
  }

  required init?(coder: NSCoder) { return nil }

  override func prepareForReuse() {
    super.prepareForReuse()
    pageIndex = nil
    requestID = UUID()
    preview.image = nil
    accessibilityIdentifier = nil
  }

  func configure(page: Int, pageCount: Int, current: Int, canSelect: Bool) {
    if pageIndex != page {
      pageIndex = page
      requestID = UUID()
      preview.image = nil
      previewStatus.text = "Loading preview…"
      accessibilityValue = "Loading preview"
    }
    isCurrentPage = page == current
    pageLabel.text = isCurrentPage ? "Page \(page + 1)\nCurrent page" : "Page \(page + 1)"
    pageLabel.font = .preferredFont(forTextStyle: .body)
    previewStatus.font = .preferredFont(forTextStyle: .caption1)
    pageLabel.textColor = .label
    previewStatus.textColor = .secondaryLabel
    contentView.backgroundColor = isCurrentPage ? .secondarySystemBackground : .systemBackground
    contentView.layer.borderWidth = isCurrentPage ? 3 : 1
    contentView.layer.borderColor = (isCurrentPage ? UIColor.label : UIColor.separator).cgColor
    accessibilityLabel = "Page \(page + 1) of \(pageCount)\(isCurrentPage ? ", current page" : "")"
    accessibilityHint =
      canSelect ? "Open this page in the PDF reader" : "Page selection is unavailable"
    accessibilityIdentifier = "pdfThumbnailPage\(page + 1)"
    accessibilityTraits = [.button]
    if isCurrentPage { accessibilityTraits.insert(.selected) }
    if !canSelect { accessibilityTraits.insert(.notEnabled) }
  }

  func show(_ image: UIImage?, page: Int, requestID: UUID) {
    guard pageIndex == page, self.requestID == requestID else { return }
    preview.image = image
    previewStatus.text = image == nil ? "Preview unavailable" : nil
    accessibilityValue = image == nil ? "Preview unavailable" : "Preview available"
  }

}
