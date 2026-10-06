import SwiftUI
import UIKit

struct BookTableView: UIViewRepresentable {
  let books: [BookCard]
  let select: (Int) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(books: books, select: select)
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
    guard context.coordinator.books != books else { return }
    let changesPage = context.coordinator.books.map(\.id) != books.map(\.id)
    context.coordinator.books = books
    table.reloadData()
    if changesPage {
      table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
    }
  }

  @MainActor
  final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
    var books: [BookCard]
    var select: (Int) -> Void

    init(books: [BookCard], select: @escaping (Int) -> Void) {
      self.books = books
      self.select = select
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
      books.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
      let cell =
        tableView.dequeueReusableCell(withIdentifier: "book", for: indexPath) as! BookTableCell
      cell.configure(books[indexPath.row])
      return cell
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
      tableView.dequeueReusableHeaderFooterView(withIdentifier: "columns")
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

  func configure(_ book: BookCard) {
    let title = book.title ?? "Untitled book"
    let authors = book.authors.isEmpty ? "Unknown author" : book.authors.joined(separator: ", ")
    let formats =
      book.files.isEmpty
      ? "No files"
      : Set(book.files.map { $0.format?.uppercased() ?? "Unknown format" }).sorted().joined(
        separator: ", ")
    columns.set([title, authors, formats])
    accessibilityLabel = title
    accessibilityValue = "\(authors); \(formats)"
    accessibilityIdentifier = "tableBook\(book.id)"
  }
}

private final class BookTableHeader: UITableViewHeaderFooterView {
  override init(reuseIdentifier: String?) {
    super.init(reuseIdentifier: reuseIdentifier)
    let background = UIView()
    background.backgroundColor = .systemBackground
    backgroundView = background
    let columns = BookTableColumns(textStyle: .headline, verticalPadding: 12)
    columns.set(["Title", "Authors", "Formats"])
    for label in columns.labels { label.accessibilityTraits = .header }
    columns.pin(to: contentView)
  }

  required init?(coder: NSCoder) { return nil }
}

private final class BookTableColumns: UIStackView {
  let labels = (0..<3).map { _ in UILabel() }

  init(textStyle: UIFont.TextStyle, verticalPadding: CGFloat) {
    super.init(frame: .zero)
    axis = .horizontal
    alignment = .center
    distribution = .fillEqually
    spacing = 12
    isLayoutMarginsRelativeArrangement = true
    layoutMargins = UIEdgeInsets(top: verticalPadding, left: 16, bottom: verticalPadding, right: 16)
    for label in labels {
      label.font = .preferredFont(forTextStyle: textStyle)
      label.adjustsFontForContentSizeCategory = true
      label.textColor = .label
      label.backgroundColor = .systemBackground
      label.numberOfLines = 2
      addArrangedSubview(label)
    }
  }

  required init(coder: NSCoder) { super.init(coder: coder) }

  func set(_ values: [String]) {
    for (label, value) in zip(labels, values) { label.text = value }
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
