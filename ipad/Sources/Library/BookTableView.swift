import SwiftUI
import UIKit

struct BookTableView: UIViewRepresentable {
  let books: [BookCard]
  var layout = BookTableLayout.defaults
  let select: (Int) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(books: books, layout: layout, select: select)
  }

  func makeUIView(context: Context) -> UITableView {
    let table = UITableView(frame: .zero, style: .plain)
    table.backgroundColor = .systemBackground
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 72
    table.sectionHeaderHeight = UITableView.automaticDimension
    table.estimatedSectionHeaderHeight = 48
    table.register(BookTableCell.self, forCellReuseIdentifier: "book")
    table.register(BookTableHeader.self, forHeaderFooterViewReuseIdentifier: "columns")
    table.dataSource = context.coordinator
    table.delegate = context.coordinator
    table.accessibilityIdentifier = "libraryTable"
    return table
  }

  func updateUIView(_ table: UITableView, context: Context) {
    context.coordinator.select = select
    let normalized = BookTableLayout.normalized(layout)
    guard context.coordinator.books != books || context.coordinator.layout != normalized else {
      return
    }
    let changesPage = context.coordinator.books.map(\.id) != books.map(\.id)
    context.coordinator.books = books
    context.coordinator.layout = normalized
    table.reloadData()
    if changesPage {
      table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
    }
  }

  @MainActor
  final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
    var books: [BookCard]
    var layout: TableLayoutState
    var select: (Int) -> Void

    init(books: [BookCard], layout: TableLayoutState, select: @escaping (Int) -> Void) {
      self.books = books
      self.layout = BookTableLayout.normalized(layout)
      self.select = select
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
      books.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
      let cell =
        tableView.dequeueReusableCell(withIdentifier: "book", for: indexPath) as! BookTableCell
      cell.configure(books[indexPath.row], layout: layout)
      return cell
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
      let header =
        tableView.dequeueReusableHeaderFooterView(withIdentifier: "columns") as! BookTableHeader
      header.configure(layout)
      return header
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
      guard books.indices.contains(indexPath.row) else { return }
      tableView.deselectRow(at: indexPath, animated: true)
      select(books[indexPath.row].id)
    }
  }
}

private final class BookTableCell: UITableViewCell {
  private let columns = BookTableColumns(textStyle: .body, verticalPadding: 8)

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .systemBackground
    columns.pin(to: contentView)
    columns.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) { return nil }

  func configure(_ book: BookCard, layout: TableLayoutState) {
    let title = book.title ?? "Untitled book"
    let visible = BookTableLayout.visible(layout)
    columns.configure(
      visible.map { BookTableLayout.text(book, column: $0) },
      widths: visible.map { layout.columnWidths[$0] }, headers: false)
    accessibilityLabel = title
    accessibilityValue = visible.filter { $0 != "title" }.map {
      BookTableLayout.text(book, column: $0)
    }.joined(separator: "; ")
    accessibilityIdentifier = "tableBook\(book.id)"
  }
}

private final class BookTableHeader: UITableViewHeaderFooterView {
  private let columns = BookTableColumns(textStyle: .headline, verticalPadding: 12)
  override init(reuseIdentifier: String?) {
    super.init(reuseIdentifier: reuseIdentifier)
    let background = UIView()
    background.backgroundColor = .systemBackground
    backgroundView = background
    columns.pin(to: contentView)
  }

  required init?(coder: NSCoder) { return nil }

  func configure(_ layout: TableLayoutState) {
    let visible = BookTableLayout.visible(layout)
    columns.configure(
      visible.map(queryFieldLabel), widths: visible.map { layout.columnWidths[$0] }, headers: true)
  }
}

private final class BookTableColumns: UIStackView {
  private let textStyle: UIFont.TextStyle
  private var widthConstraints: [NSLayoutConstraint] = []

  init(textStyle: UIFont.TextStyle, verticalPadding: CGFloat) {
    self.textStyle = textStyle
    super.init(frame: .zero)
    axis = .horizontal
    alignment = .center
    distribution = .fillEqually
    spacing = 12
    isLayoutMarginsRelativeArrangement = true
    layoutMargins = UIEdgeInsets(top: verticalPadding, left: 16, bottom: verticalPadding, right: 16)
  }

  required init(coder: NSCoder) {
    textStyle = .body
    super.init(coder: coder)
  }

  func configure(_ values: [String], widths: [Double?], headers: Bool) {
    NSLayoutConstraint.deactivate(widthConstraints)
    widthConstraints = []
    for view in arrangedSubviews {
      removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    distribution = widths.contains { $0 != nil } ? .fill : .fillEqually
    for (index, value) in values.enumerated() {
      let label = UILabel()
      label.font = .preferredFont(forTextStyle: textStyle)
      label.adjustsFontForContentSizeCategory = true
      label.textColor = .label
      label.backgroundColor = .systemBackground
      label.numberOfLines = 0
      label.text = value
      if headers { label.accessibilityTraits = .header }
      addArrangedSubview(label)
      if distribution == .fill {
        let width = CGFloat(widths[index] ?? 180)
        let constraint = label.widthAnchor.constraint(equalToConstant: width)
        constraint.priority = .defaultHigh
        widthConstraints.append(constraint)
      }
    }
    NSLayoutConstraint.activate(widthConstraints)
  }

  func pin(to view: UIView) {
    translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(self)
    NSLayoutConstraint.activate([
      leadingAnchor.constraint(equalTo: view.leadingAnchor),
      trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topAnchor.constraint(equalTo: view.topAnchor),
      bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }
}
