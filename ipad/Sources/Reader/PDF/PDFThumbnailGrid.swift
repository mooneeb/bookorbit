import PDFKit
import SwiftUI
import UIKit

struct PDFThumbnailGrid: UIViewControllerRepresentable {
  let document: PDFDocument
  let currentPage: Int
  let rotation: Int
  let canSelect: Bool
  let authorize: @MainActor () async -> Bool
  let unavailable: () -> Void
  let onSelect: (Int) -> Void

  func makeUIViewController(context: Context) -> PDFThumbnailGridController {
    let controller = PDFThumbnailGridController()
    update(controller)
    return controller
  }

  func updateUIViewController(_ controller: PDFThumbnailGridController, context: Context) {
    update(controller)
  }

  static func dismantleUIViewController(_ controller: PDFThumbnailGridController, coordinator: ()) {
    controller.stop()
  }

  private func update(_ controller: PDFThumbnailGridController) {
    controller.configure(
      document: document, currentPage: currentPage, rotation: rotation, canSelect: canSelect,
      authorize: authorize, unavailable: unavailable, onSelect: onSelect)
  }
}

@MainActor
final class PDFThumbnailGridController: UICollectionViewController {
  private let layout = UICollectionViewFlowLayout()
  private let renderer = PDFThumbnailRenderer()
  private var documentID: ObjectIdentifier?
  private var pageCount = 0
  private var currentPage = 0
  private var rotation = 0
  private var canSelect = false
  private var onSelect: ((Int) -> Void)?
  private var needsInitialScroll = true
  private var displayedRequests: [ObjectIdentifier: (page: Int, id: UUID)] = [:]

  init() { super.init(collectionViewLayout: layout) }
  required init?(coder: NSCoder) { return nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    collectionView.backgroundColor = .systemBackground
    collectionView.isPrefetchingEnabled = false
    collectionView.accessibilityIdentifier = "pdfThumbnailGrid"
    collectionView.register(
      PDFThumbnailCell.self, forCellWithReuseIdentifier: PDFThumbnailCell.reuseIdentifier)
    layout.minimumInteritemSpacing = 12
    layout.minimumLineSpacing = 12
    layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    registerForTraitChanges([
      UITraitPreferredContentSizeCategory.self, UITraitHorizontalSizeClass.self,
      UITraitVerticalSizeClass.self,
    ]) { (controller: PDFThumbnailGridController, _: UITraitCollection) in
      controller.view.setNeedsLayout()
    }
  }

  func configure(
    document: PDFDocument, currentPage: Int, rotation: Int, canSelect: Bool,
    authorize: @escaping @MainActor () async -> Bool, unavailable: @escaping () -> Void,
    onSelect: @escaping (Int) -> Void
  ) {
    let changed = documentID != ObjectIdentifier(document) || self.rotation != rotation
    documentID = ObjectIdentifier(document)
    pageCount = document.pageCount
    self.currentPage = currentPage
    self.rotation = rotation
    self.canSelect = canSelect
    self.onSelect = onSelect
    renderer.configure(
      document: document, rotation: rotation, authorize: authorize, unavailable: unavailable)
    loadViewIfNeeded()
    if changed {
      needsInitialScroll = true
      collectionView.reloadData()
    } else {
      for cell in collectionView.visibleCells {
        guard let cell = cell as? PDFThumbnailCell, let page = cell.pageIndex else { continue }
        configure(cell, page: page)
      }
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateLayout()
    if needsInitialScroll, pageCount > 0, collectionView.bounds.width > 0 {
      needsInitialScroll = false
      collectionView.scrollToItem(
        at: IndexPath(item: currentPage, section: 0), at: .centeredVertically, animated: false)
    }
  }

  private func updateLayout() {
    let width = max(1, collectionView.bounds.width - 24)
    let largeType = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    let minimumWidth: CGFloat = largeType ? 240 : 160
    let columns = max(1, min(6, Int((width + 12) / (minimumWidth + 12))))
    let cellWidth = max(1, (width - CGFloat(columns - 1) * 12) / CGFloat(columns))
    let digits = String(repeating: "8", count: String(max(1, pageCount)).count)
    let bodyHeight = textHeight(
      "Page \(digits)\nCurrent page", font: .preferredFont(forTextStyle: .body),
      width: cellWidth - 16)
    let captionFont = UIFont.preferredFont(forTextStyle: .caption1)
    let captionHeight = max(
      textHeight("Loading preview…", font: captionFont, width: cellWidth - 16),
      textHeight("Preview unavailable", font: captionFont, width: cellWidth - 16))
    let size = CGSize(
      width: cellWidth, height: 180 + bodyHeight + captionHeight + 32)
    if layout.itemSize != size {
      layout.itemSize = size
      layout.invalidateLayout()
    }
  }

  private func textHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
    ceil(
      (text as NSString).boundingRect(
        with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font],
        context: nil
      ).height)
  }

  override func collectionView(
    _ collectionView: UICollectionView, numberOfItemsInSection section: Int
  )
    -> Int
  {
    pageCount
  }

  override func collectionView(
    _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
  ) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: PDFThumbnailCell.reuseIdentifier, for: indexPath)
    if let thumbnail = cell as? PDFThumbnailCell { configure(thumbnail, page: indexPath.item) }
    return cell
  }

  override func collectionView(
    _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    guard let cell = cell as? PDFThumbnailCell else { return }
    let page = indexPath.item
    let id = cell.requestID
    let key = ObjectIdentifier(cell)
    if let previous = displayedRequests[key] {
      renderer.release(page: previous.page, id: previous.id)
    }
    displayedRequests[key] = (page, id)
    renderer.request(page: page, id: id) { [weak cell] image in
      cell?.show(image, page: page, requestID: id)
    }
  }

  override func collectionView(
    _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    let key = ObjectIdentifier(cell)
    guard let request = displayedRequests[key], request.page == indexPath.item else { return }
    displayedRequests.removeValue(forKey: key)
    renderer.release(page: request.page, id: request.id)
  }

  override func collectionView(
    _ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath
  ) {
    collectionView.deselectItem(at: indexPath, animated: false)
    guard canSelect, (0..<pageCount).contains(indexPath.item) else { return }
    onSelect?(indexPath.item)
  }

  private func configure(_ cell: PDFThumbnailCell, page: Int) {
    cell.configure(page: page, pageCount: pageCount, current: currentPage, canSelect: canSelect)
  }

  func stop() {
    renderer.stop()
    displayedRequests.removeAll()
    onSelect = nil
    documentID = nil
    pageCount = 0
  }
}
