import SwiftUI
import UIKit

struct BookTableView: UIViewRepresentable {
  let books: [BookCard]
  var layout = BookTableLayout.defaults
  let renderer: BookTableColumnRenderer
  var density = BookTableDensity.comfortable
  let select: (Int) -> Void
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  func makeCoordinator() -> Coordinator {
    Coordinator(
      books: books, layout: layout, renderer: renderer, density: density,
      dynamicTypeSize: dynamicTypeSize, select: select)
  }

  func makeUIView(context: Context) -> BookTableViewport {
    let viewport = BookTableViewport()
    viewport.delegate = context.coordinator
    viewport.table.dataSource = context.coordinator
    viewport.table.delegate = context.coordinator
    viewport.layout = context.coordinator.layout
    viewport.customFields = renderer.customFields
    viewport.geometryChanged = { [weak coordinator = context.coordinator] in
      coordinator?.updateVisibleColumns()
    }
    context.coordinator.viewport = viewport
    return viewport
  }

  func updateUIView(_ viewport: BookTableViewport, context: Context) {
    let coordinator = context.coordinator
    coordinator.select = select
    let normalized = BookTableLayout.normalized(layout, customFields: renderer.customFields)
    let changed =
      coordinator.books != books || coordinator.layout != normalized
      || coordinator.density != density || coordinator.dynamicTypeSize != dynamicTypeSize
      || coordinator.renderer.customFields != renderer.customFields
      || coordinator.renderer.canEditMetadata != renderer.canEditMetadata
      || coordinator.renderer.canRead != renderer.canRead
      || coordinator.renderer.isBusy != renderer.isBusy
      || coordinator.renderer.sort != renderer.sort
      || coordinator.renderer.descending != renderer.descending
      || coordinator.renderer.api !== renderer.api
    coordinator.renderer = renderer
    guard changed else { return }
    let changesPage = coordinator.books.map(\.id) != books.map(\.id)
    let changesLayout = coordinator.layout != normalized
    coordinator.books = books
    coordinator.layout = normalized
    coordinator.density = density
    coordinator.dynamicTypeSize = dynamicTypeSize
    viewport.layout = normalized
    viewport.customFields = renderer.customFields
    if changesLayout {
      coordinator.leftOffset = 0
      coordinator.rightOffset = 0
      viewport.setContentOffset(.zero, animated: false)
    }
    viewport.setNeedsLayout()
    viewport.table.reloadData()
    if changesPage {
      viewport.table.setContentOffset(
        CGPoint(x: 0, y: -viewport.table.adjustedContentInset.top), animated: false)
    }
  }

  @MainActor
  final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
    var books: [BookCard]
    var layout: TableLayoutState
    var renderer: BookTableColumnRenderer
    var density: BookTableDensity
    var dynamicTypeSize: DynamicTypeSize
    var select: (Int) -> Void
    weak var viewport: BookTableViewport?
    var leftOffset: CGFloat = 0
    var rightOffset: CGFloat = 0

    init(
      books: [BookCard], layout: TableLayoutState, renderer: BookTableColumnRenderer,
      density: BookTableDensity, dynamicTypeSize: DynamicTypeSize, select: @escaping (Int) -> Void
    ) {
      self.books = books
      self.layout = BookTableLayout.normalized(layout, customFields: renderer.customFields)
      self.renderer = renderer
      self.density = density
      self.dynamicTypeSize = dynamicTypeSize
      self.select = select
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
      books.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
      let cell =
        tableView.dequeueReusableCell(withIdentifier: "book", for: indexPath) as! BookTableCell
      let book = books[indexPath.row]
      cell.configure(book, layout: layout, renderer: renderer, density: density)
      configureOffsets(cell.columns)
      return cell
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
      let header =
        tableView.dequeueReusableHeaderFooterView(withIdentifier: "columns") as! BookTableHeader
      header.configure(layout, renderer: renderer)
      configureOffsets(header.columns)
      return header
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
      guard books.indices.contains(indexPath.row) else { return }
      tableView.deselectRow(at: indexPath, animated: true)
      select(books[indexPath.row].id)
    }

    func tableView(
      _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
      point: CGPoint
    ) -> UIContextMenuConfiguration? {
      guard books.indices.contains(indexPath.row) else { return nil }
      let book = books[indexPath.row]
      return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
        self?.renderer.makeMenu(book: book)
      }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      guard scrollView === viewport || scrollView === viewport?.table else { return }
      updateVisibleColumns()
    }

    func updateVisibleColumns() {
      guard let viewport else { return }
      for case let cell as BookTableCell in viewport.table.visibleCells {
        configureOffsets(cell.columns)
      }
      if let header = viewport.table.headerView(forSection: 0) as? BookTableHeader {
        configureOffsets(header.columns)
      }
    }

    private func configureOffsets(_ columns: BookTableColumns) {
      guard let viewport else { return }
      columns.sideScrolled = { [weak self] side, offset in
        guard let self else { return }
        if side == "left" { self.leftOffset = offset } else { self.rightOffset = offset }
        self.updateVisibleColumns()
      }
      columns.setViewport(
        offset: viewport.contentOffset.x, width: viewport.bounds.width,
        leftOffset: leftOffset, rightOffset: rightOffset)
    }
  }
}

final class BookTableViewport: UIScrollView {
  let table = UITableView(frame: .zero, style: .plain)
  var layout = BookTableLayout.defaults
  var customFields: [CustomMetadataFieldSummary] = []
  var geometryChanged: (() -> Void)?

  init() {
    super.init(frame: .zero)
    backgroundColor = .systemBackground
    isDirectionalLockEnabled = true
    alwaysBounceVertical = false
    showsVerticalScrollIndicator = false
    accessibilityIdentifier = "libraryTableViewport"
    table.backgroundColor = .systemBackground
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 72
    table.sectionHeaderHeight = UITableView.automaticDimension
    table.estimatedSectionHeaderHeight = 68
    table.register(BookTableCell.self, forCellReuseIdentifier: "book")
    table.register(BookTableHeader.self, forHeaderFooterViewReuseIdentifier: "columns")
    table.accessibilityIdentifier = "libraryTable"
    addSubview(table)
  }

  required init?(coder: NSCoder) { return nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    let geometry = BookTableGeometry(
      layout: layout, customFields: customFields, available: bounds.width)
    table.frame = CGRect(x: 0, y: 0, width: geometry.contentWidth, height: bounds.height)
    contentSize = CGSize(width: geometry.contentWidth, height: bounds.height)
    geometryChanged?()
  }
}

@MainActor private struct BookTableGeometry {
  let left: [String]
  let center: [String]
  let right: [String]
  let leftWidth: CGFloat
  let rightWidth: CGFloat
  let contentWidth: CGFloat

  init(layout: TableLayoutState, customFields: [CustomMetadataFieldSummary], available: CGFloat) {
    let visible = BookTableLayout.visible(layout, customFields: customFields)
    left = visible.filter { BookTableLayout.pinSide($0, layout: layout) == "left" }
    center = visible.filter { BookTableLayout.pinSide($0, layout: layout) == nil }
    right = visible.filter { BookTableLayout.pinSide($0, layout: layout) == "right" }
    func width(_ columns: [String]) -> CGFloat {
      CGFloat(columns.reduce(0) { $0 + BookTableLayout.width($1, layout: layout) })
        + CGFloat(max(0, columns.count - 1)) * 12
    }
    let leftNatural = left.isEmpty ? 0 : width(left) + 22
    let rightNatural = right.isEmpty ? 0 : width(right) + 22
    let fraction: CGFloat = center.isEmpty ? 0.5 : (left.isEmpty || right.isEmpty ? 0.6 : 0.4)
    leftWidth = min(leftNatural, available * (right.isEmpty && center.isEmpty ? 1 : fraction))
    rightWidth = min(rightNatural, available * (left.isEmpty && center.isEmpty ? 1 : fraction))
    let centerNatural =
      center.isEmpty ? 0 : width(center) + (left.isEmpty ? 16 : 6) + (right.isEmpty ? 16 : 6)
    contentWidth = max(available, leftWidth + centerNatural + rightWidth)
  }
}

private final class BookTableCell: UITableViewCell {
  let columns = BookTableColumns()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .systemBackground
    columns.pin(to: contentView)
    isAccessibilityElement = false
  }

  required init?(coder: NSCoder) { return nil }

  func configure(
    _ book: BookCard, layout: TableLayoutState, renderer: BookTableColumnRenderer,
    density: BookTableDensity
  ) {
    columns.configure(
      layout: layout, customFields: renderer.customFields, padding: CGFloat(density.verticalPadding)
    ) { renderer.makeCell(book: book, column: $0) }
    accessibilityLabel = book.title ?? "Untitled book"
    accessibilityIdentifier = "tableBook\(book.id)"
  }
}

private final class BookTableHeader: UITableViewHeaderFooterView {
  let columns = BookTableColumns()

  override init(reuseIdentifier: String?) {
    super.init(reuseIdentifier: reuseIdentifier)
    let background = UIView()
    background.backgroundColor = .systemBackground
    backgroundView = background
    columns.pin(to: contentView)
  }

  required init?(coder: NSCoder) { return nil }

  func configure(_ layout: TableLayoutState, renderer: BookTableColumnRenderer) {
    columns.configure(layout: layout, customFields: renderer.customFields, padding: 12) {
      renderer.makeHeader(column: $0)
    }
  }
}

private final class BookTableColumns: UIView, UIScrollViewDelegate {
  private let left = UIScrollView()
  private let centerContent = UIView()
  private let right = UIScrollView()
  private var views: [String: UIView] = [:]
  private var layout = BookTableLayout.defaults
  private var customFields: [CustomMetadataFieldSummary] = []
  private var padding: CGFloat = 8
  private var horizontalOffset: CGFloat = 0
  private var viewportWidth: CGFloat = 0
  private var leftOffset: CGFloat = 0
  private var rightOffset: CGFloat = 0
  private var updatingOffsets = false
  private var height: NSLayoutConstraint?
  var sideScrolled: ((String, CGFloat) -> Void)?

  init() {
    super.init(frame: .zero)
    backgroundColor = .systemBackground
    centerContent.clipsToBounds = true
    for region in [centerContent, left, right] {
      region.backgroundColor = .systemBackground
      addSubview(region)
    }
    for scroll in [left, right] {
      scroll.delegate = self
      scroll.isDirectionalLockEnabled = true
      scroll.showsVerticalScrollIndicator = false
    }
    left.accessibilityIdentifier = "leftPinnedColumns"
    right.accessibilityIdentifier = "rightPinnedColumns"
  }

  required init?(coder: NSCoder) { return nil }

  func configure(
    layout: TableLayoutState, customFields: [CustomMetadataFieldSummary], padding: CGFloat,
    content: (String) -> UIView
  ) {
    for view in views.values { view.removeFromSuperview() }
    views = [:]
    self.layout = layout
    self.customFields = customFields
    self.padding = padding
    var requiredHeight: CGFloat = 44
    for column in BookTableLayout.visible(layout, customFields: customFields) {
      let view = content(column)
      view.translatesAutoresizingMaskIntoConstraints = true
      views[column] = view
      switch BookTableLayout.pinSide(column, layout: layout) {
      case "left": left.addSubview(view)
      case "right": right.addSubview(view)
      default: centerContent.addSubview(view)
      }
      requiredHeight = max(
        requiredHeight,
        view.sizeThatFits(
          CGSize(
            width: CGFloat(BookTableLayout.width(column, layout: layout)),
            height: .greatestFiniteMagnitude)
        ).height)
    }
    height?.constant = requiredHeight + padding * 2
    setNeedsLayout()
  }

  func setViewport(offset: CGFloat, width: CGFloat, leftOffset: CGFloat, rightOffset: CGFloat) {
    horizontalOffset = offset
    viewportWidth = width
    self.leftOffset = leftOffset
    self.rightOffset = rightOffset
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let geometry = BookTableGeometry(
      layout: layout, customFields: customFields, available: viewportWidth)
    left.frame = CGRect(x: horizontalOffset, y: 0, width: geometry.leftWidth, height: bounds.height)
    right.frame = CGRect(
      x: horizontalOffset + viewportWidth - geometry.rightWidth, y: 0,
      width: geometry.rightWidth, height: bounds.height)
    centerContent.frame = CGRect(
      x: horizontalOffset + geometry.leftWidth, y: 0,
      width: max(0, viewportWidth - geometry.leftWidth - geometry.rightWidth), height: bounds.height
    )
    func arrange(_ columns: [String], start: CGFloat) -> CGFloat {
      var x = start
      for column in columns {
        let width = CGFloat(BookTableLayout.width(column, layout: layout))
        views[column]?.frame = CGRect(
          x: x, y: padding, width: width, height: max(44, bounds.height - padding * 2))
        x += width + 12
      }
      return columns.isEmpty ? 0 : x - 12
    }
    let leftNatural = arrange(geometry.left, start: 16) + (geometry.left.isEmpty ? 0 : 6)
    let rightNatural = arrange(geometry.right, start: 6) + (geometry.right.isEmpty ? 0 : 16)
    _ = arrange(geometry.center, start: (geometry.left.isEmpty ? 16 : 6) - horizontalOffset)
    left.contentSize = CGSize(width: leftNatural, height: bounds.height)
    right.contentSize = CGSize(width: rightNatural, height: bounds.height)
    updatingOffsets = true
    left.contentOffset = CGPoint(
      x: min(max(0, leftOffset), max(0, leftNatural - geometry.leftWidth)), y: 0)
    right.contentOffset = CGPoint(
      x: min(max(0, rightOffset), max(0, rightNatural - geometry.rightWidth)), y: 0)
    updatingOffsets = false
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard !updatingOffsets else { return }
    sideScrolled?(scrollView === left ? "left" : "right", max(0, scrollView.contentOffset.x))
  }

  func pin(to view: UIView) {
    translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(self)
    height = heightAnchor.constraint(equalToConstant: 60)
    NSLayoutConstraint.activate([
      leadingAnchor.constraint(equalTo: view.leadingAnchor),
      trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topAnchor.constraint(equalTo: view.topAnchor),
      bottomAnchor.constraint(equalTo: view.bottomAnchor), height!,
    ])
  }
}
