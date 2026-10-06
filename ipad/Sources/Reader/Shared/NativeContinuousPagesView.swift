import SwiftUI
import UIKit

struct NativeContinuousPagesView: UIViewControllerRepresentable {
  let pageCount: Int
  let pageIndex: Int
  let horizontal: Bool
  let gap: CGFloat
  let identifier: String
  let height: (Int, CGFloat) -> CGFloat
  let makePage: (Int) -> UIViewController
  let refreshPage: (UIViewController, Int) -> Void
  let onTurn: (Int) -> Void
  let onVisible: (Set<Int>) -> Void

  func makeUIViewController(context: Context) -> ContinuousPagesController {
    ContinuousPagesController(configuration: self)
  }

  func updateUIViewController(_ controller: ContinuousPagesController, context: Context) {
    controller.update(self)
  }
}

@MainActor
final class ContinuousPagesController: UIViewController,
  UICollectionViewDataSource, UICollectionViewDelegate
{
  private var configuration: NativeContinuousPagesView
  private let layout = ContinuousPageLayout()
  private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
  private var currentIndex: Int
  private var previousSize = CGSize.zero
  private var applying = false
  private var installed = false
  private var visibleIndices: Set<Int> = []

  init(configuration: NativeContinuousPagesView) {
    self.configuration = configuration
    currentIndex = configuration.pageIndex
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func loadView() {
    view = UIView()
    view.backgroundColor = .systemBackground
    view.accessibilityIdentifier = configuration.identifier
    collection.backgroundColor = .systemBackground
    collection.dataSource = self
    collection.delegate = self
    collection.isPrefetchingEnabled = false
    collection.contentInsetAdjustmentBehavior = .never
    collection.bounces = false
    collection.accessibilityIdentifier = "\(configuration.identifier)Continuous"
    collection.register(PageHostCell.self, forCellWithReuseIdentifier: "page")
    view.addSubview(collection)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard view.bounds.width > 0, view.bounds.height > 0 else { return }
    collection.frame = view.bounds
    if previousSize != view.bounds.size {
      let fraction = layout.fraction(at: collection.contentOffset, index: currentIndex)
      previousSize = view.bounds.size
      applying = true
      configureLayout()
      collection.layoutIfNeeded()
      scrollToCurrent(fraction: fraction)
      applying = false
      reportVisible()
    }
  }

  func update(_ configuration: NativeContinuousPagesView) {
    self.configuration = configuration
    loadViewIfNeeded()
    applying = true
    let changedIndex = configuration.pageIndex != currentIndex
    let fraction = layout.fraction(at: collection.contentOffset, index: currentIndex)
    currentIndex = configuration.pageIndex
    configureLayout()
    collection.layoutIfNeeded()
    for path in collection.indexPathsForVisibleItems {
      if let cell = collection.cellForItem(at: path) as? PageHostCell, let page = cell.page {
        configuration.refreshPage(page, path.item)
      }
    }
    scrollToCurrent(fraction: changedIndex || !installed ? 0 : fraction)
    installed = true
    applying = false
    reportVisible()
  }

  private func configureLayout() {
    layout.configure(
      count: configuration.pageCount, size: collection.bounds.size,
      horizontal: configuration.horizontal, gap: configuration.gap, around: currentIndex,
      visible: Set(collection.indexPathsForVisibleItems.map(\.item)),
      height: configuration.height)
  }

  private func scrollToCurrent(fraction: CGFloat = 0) {
    guard (0..<configuration.pageCount).contains(currentIndex), collection.bounds.width > 0,
      collection.bounds.height > 0
    else { return }
    guard
      let frame = layout.layoutAttributesForItem(at: IndexPath(item: currentIndex, section: 0))?
        .frame
    else { return }
    let desired =
      configuration.horizontal
      ? frame.minX + fraction * frame.width : frame.minY + fraction * frame.height
    let content = layout.collectionViewContentSize
    let maximum =
      configuration.horizontal
      ? content.width - collection.bounds.width : content.height - collection.bounds.height
    let offset = min(max(0, desired), max(0, maximum))
    collection.contentOffset =
      configuration.horizontal ? CGPoint(x: offset, y: 0) : CGPoint(x: 0, y: offset)
  }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
    -> Int
  {
    configuration.pageCount
  }

  func collectionView(
    _ collectionView: UICollectionView, cellForItemAt path: IndexPath
  ) -> UICollectionViewCell {
    collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: path)
  }

  func collectionView(
    _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
    forItemAt path: IndexPath
  ) {
    guard let cell = cell as? PageHostCell else { return }
    cell.install(configuration.makePage(path.item), parent: self)
    if let page = cell.page { configuration.refreshPage(page, path.item) }
  }

  func collectionView(
    _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    (cell as? PageHostCell)?.detach()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard !applying, installed else { return }
    let point = CGPoint(
      x: scrollView.contentOffset.x + (configuration.horizontal ? 20 : scrollView.bounds.midX),
      y: scrollView.contentOffset.y + (configuration.horizontal ? scrollView.bounds.midY : 20))
    let offset = configuration.horizontal ? point.x : point.y
    let index = layout.index(at: offset)
    if (0..<configuration.pageCount).contains(index), index != currentIndex {
      currentIndex = index
      configuration.onTurn(index)
    }
    reportVisible()
  }

  private func reportVisible() {
    let indices = Set(
      (layout.layoutAttributesForElements(in: collection.bounds) ?? []).map(\.indexPath.item))
    guard !indices.isEmpty, indices != visibleIndices else { return }
    visibleIndices = indices
    DispatchQueue.main.async { [weak self] in
      guard let self, self.visibleIndices == indices else { return }
      self.configuration.onVisible(indices)
    }
  }
}

@MainActor private final class ContinuousPageLayout: UICollectionViewLayout {
  private var count = 0
  private var size = CGSize.zero
  private var horizontal = false
  private var gap: CGFloat = 0
  private var heights: [Int: CGFloat] = [:]
  private var estimatedHeight: CGFloat { max(120, size.height) }
  private var stride: CGFloat { (horizontal ? max(1, size.width) : estimatedHeight) + gap }

  func configure(
    count: Int, size: CGSize, horizontal: Bool, gap: CGFloat,
    around index: Int, visible: Set<Int>, height: (Int, CGFloat) -> CGFloat
  ) {
    if self.size != size || self.horizontal != horizontal || self.count != count {
      heights.removeAll()
    }
    self.count = count
    self.size = size
    self.horizontal = horizontal
    self.gap = gap
    if !horizontal {
      let measured = visible.union([index - 1, index, index + 1]).filter {
        (0..<count).contains($0)
      }
      for page in measured {
        let value = height(page, max(1, size.width))
        heights[page] = value.isFinite ? max(120, value) : estimatedHeight
      }
      if heights.count > 64 {
        let nearest = heights.keys.sorted {
          let left = abs($0 - index)
          let right = abs($1 - index)
          return left == right ? $0 < $1 : left < right
        }.prefix(64)
        heights = Dictionary(
          uniqueKeysWithValues: nearest.compactMap { key in heights[key].map { (key, $0) } })
      }
    }
    invalidateLayout()
  }

  override var collectionViewContentSize: CGSize {
    let extent = max(0, start(of: count) - gap)
    return horizontal
      ? CGSize(width: extent, height: size.height) : CGSize(width: size.width, height: extent)
  }

  private func start(of index: Int) -> CGFloat {
    CGFloat(index) * stride
      + (horizontal
        ? 0
        : heights.reduce(CGFloat.zero) { result, item in
          result + (item.key < index ? item.value - estimatedHeight : 0)
        })
  }

  func index(at offset: CGFloat) -> Int {
    guard count > 0 else { return 0 }
    var lower = 0
    var upper = count
    while lower < upper {
      let middle = (lower + upper) / 2
      if start(of: middle + 1) <= offset { lower = middle + 1 } else { upper = middle }
    }
    return min(count - 1, lower)
  }

  func fraction(at offset: CGPoint, index: Int) -> CGFloat {
    guard let frame = layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else {
      return 0
    }
    let length = horizontal ? frame.width : frame.height
    let distance = horizontal ? offset.x - frame.minX : offset.y - frame.minY
    return min(1, max(0, distance / max(1, length)))
  }

  override func layoutAttributesForItem(at path: IndexPath) -> UICollectionViewLayoutAttributes? {
    guard (0..<count).contains(path.item) else { return nil }
    let attributes = UICollectionViewLayoutAttributes(forCellWith: path)
    let origin = start(of: path.item)
    attributes.frame =
      horizontal
      ? CGRect(x: origin, y: 0, width: size.width, height: size.height)
      : CGRect(x: 0, y: origin, width: size.width, height: heights[path.item] ?? estimatedHeight)
    return attributes
  }

  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]?
  {
    guard count > 0 else { return [] }
    let first = index(at: horizontal ? rect.minX : rect.minY)
    let last = index(at: horizontal ? rect.maxX : rect.maxY)
    return (first...last).compactMap {
      layoutAttributesForItem(at: IndexPath(item: $0, section: 0))
    }
    .filter { $0.frame.intersects(rect) }
  }
}

@MainActor private final class PageHostCell: UICollectionViewCell {
  private(set) var page: UIViewController?

  func install(_ controller: UIViewController, parent: UIViewController) {
    detach()
    parent.addChild(controller)
    controller.view.frame = contentView.bounds
    controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contentView.addSubview(controller.view)
    controller.didMove(toParent: parent)
    page = controller
  }

  func detach() {
    page?.willMove(toParent: nil)
    page?.view.removeFromSuperview()
    page?.removeFromParent()
    page = nil
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    detach()
  }
}
