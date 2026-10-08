import UIKit

@MainActor enum BookTableSeriesGroupPresentation {
  static func makeCell(
    api: BookOrbitAPI, book: BookCard, column: String, isBusy: Bool,
    openSeries: @escaping @MainActor () -> Void, openBook: @escaping @MainActor (Int) -> Void
  ) -> UIView {
    if column == "cover" {
      return SeriesTableCoverButton(api: api, book: book, isBusy: isBusy, openSeries: openSeries)
    }
    if column == "title" || column == "seriesName" {
      let control = SeriesTableButton(type: .system)
      control.setTitle(
        (book.seriesName ?? "Series") + "\n" + book.seriesGroupCountText, for: .normal)
      control.isEnabled = !isBusy && book.seriesId != nil
      control.addAction(UIAction { _ in openSeries() }, for: .touchUpInside)
      control.accessibilityLabel = book.seriesName ?? "Series"
      control.accessibilityValue = book.seriesGroupCountText
      control.accessibilityHint = "Open series contents"
      control.accessibilityIdentifier = "tableSeriesGroup\(book.id)_\(column)"
      return control
    }
    if column == "actions" {
      let control = SeriesTableButton(type: .system)
      control.setImage(UIImage(systemName: "ellipsis"), for: .normal)
      control.menu = makeMenu(
        book: book, isBusy: isBusy, openSeries: openSeries, openBook: openBook)
      control.showsMenuAsPrimaryAction = true
      control.isEnabled = !isBusy
      control.accessibilityLabel = "Series actions for \(book.seriesName ?? "Series")"
      control.accessibilityIdentifier = "tableSeriesGroupActions\(book.id)"
      return control
    }
    let label = UILabel()
    label.text = column == "lockRow" ? "Series" : "-"
    label.font = .preferredFont(forTextStyle: .body)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .label
    label.numberOfLines = 0
    label.accessibilityLabel =
      column == "lockRow" ? "Series group" : "Not available for a series group"
    return label
  }

  static func makeMenu(
    book: BookCard, isBusy: Bool, openSeries: @escaping @MainActor () -> Void,
    openBook: @escaping @MainActor (Int) -> Void
  ) -> UIMenu {
    var children: [UIMenuElement] = []
    if book.seriesId != nil {
      children.append(
        UIAction(
          title: "Series contents", image: UIImage(systemName: "books.vertical"),
          attributes: isBusy ? .disabled : []
        ) { _ in openSeries() })
    }
    for (title, id) in [
      ("Open first volume", book.collapsedSeries?.firstVolumeBookId),
      ("Open latest volume", book.collapsedSeries?.latestVolumeBookId),
      ("Open first unread", book.collapsedSeries?.firstUnreadBookId),
    ] {
      if let id, id > 0 {
        children.append(
          UIAction(
            title: title, image: UIImage(systemName: "book"), attributes: isBusy ? .disabled : []
          ) { _ in openBook(id) })
      }
    }
    return UIMenu(title: book.seriesName ?? "Series", children: children)
  }

  static func fittingWidth(book: BookCard, column: String) -> CGFloat {
    guard column == "title" || column == "seriesName" else { return 80 }
    let font = UIFont.preferredFont(forTextStyle: .body)
    return min(
      800,
      max(
        160,
        [book.seriesName ?? "Series", book.seriesGroupCountText].map {
          ($0 as NSString).size(withAttributes: [.font: font]).width + 12
        }.max() ?? 160))
  }
}

private final class SeriesTableButton: UIButton {
  override init(frame: CGRect) {
    super.init(frame: frame)
    setTitleColor(.label, for: .normal)
    tintColor = .label
    titleLabel?.font = .preferredFont(forTextStyle: .body)
    titleLabel?.adjustsFontForContentSizeCategory = true
    titleLabel?.numberOfLines = 0
    titleLabel?.lineBreakMode = .byWordWrapping
    contentHorizontalAlignment = .leading
  }

  required init?(coder: NSCoder) { return nil }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let height =
      titleLabel?.sizeThatFits(CGSize(width: size.width, height: .greatestFiniteMagnitude)).height
      ?? 0
    return CGSize(width: size.width, height: max(44, height + 8))
  }
}

private final class SeriesTableCoverButton: UIButton {
  private let api: BookOrbitAPI
  private let book: BookCard
  private var covers: [(id: Int, image: UIImageView)] = []
  private var loading: [Task<Void, Never>] = []
  private var operation = UUID()
  private var loadedIDs = Set<Int>()
  private var failedIDs = Set<Int>()

  init(api: BookOrbitAPI, book: BookCard, isBusy: Bool, openSeries: @escaping @MainActor () -> Void)
  {
    self.api = api
    self.book = book
    super.init(frame: .zero)
    tintColor = .label
    isEnabled = !isBusy && book.seriesId != nil
    for id in (book.collapsedSeries?.coverBookIds ?? []).prefix(4) where id > 0 {
      guard !covers.contains(where: { $0.id == id }) else { continue }
      let image = UIImageView(image: UIImage(systemName: "book.closed"))
      image.contentMode = .scaleAspectFit
      image.tintColor = .label
      image.isAccessibilityElement = false
      addSubview(image)
      covers.append((id, image))
    }
    if covers.isEmpty { setImage(UIImage(systemName: "books.vertical"), for: .normal) }
    accessibilityLabel = "Covers for \(book.seriesName ?? "Series")"
    accessibilityValue = book.seriesGroupCountText
    accessibilityHint = "Open series contents"
    accessibilityIdentifier = "tableSeriesGroupCover\(book.id)"
    addAction(UIAction { _ in openSeries() }, for: .touchUpInside)
    accessibilityCustomActions = [
      UIAccessibilityCustomAction(name: "Retry series covers") { [weak self] _ in
        self?.retry()
        return true
      }
    ]
    menu = UIMenu(children: [
      UIAction(title: "Retry series covers", image: UIImage(systemName: "arrow.clockwise")) {
        [weak self] _ in self?.retry()
      }
    ])
  }

  required init?(coder: NSCoder) { return nil }

  override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: 56) }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = max(
      1, (bounds.width - CGFloat(max(0, covers.count - 1)) * 2) / CGFloat(max(1, covers.count)))
    for (index, cover) in covers.enumerated() {
      cover.image.frame = CGRect(
        x: CGFloat(index) * (width + 2), y: 2, width: width, height: bounds.height - 4)
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil { cancel() } else { load() }
  }

  private func retry() {
    cancel()
    failedIDs = []
    load()
  }

  private func cancel() {
    operation = UUID()
    for task in loading { task.cancel() }
    loading = []
  }

  private func load() {
    guard window != nil, loading.isEmpty else { return }
    let operation = self.operation
    for cover in covers where !loadedIDs.contains(cover.id) {
      let version =
        cover.id == book.id
        ? book.coverVersion
        : (book.collapsedSeries?.coverUpdatedAtByBookId?[String(cover.id)] ?? nil) ?? ""
      loading.append(
        Task { [weak self] in
          guard let self else { return }
          do {
            let namespace = try await api.imageNamespace()
            let image = try await CoverPreviewLoader.shared.thumbnail(
              api: api, bookID: cover.id, version: version, namespace: namespace)
            try Task.checkCancellation()
            guard self.operation == operation else { return }
            cover.image.image = image
            loadedIDs.insert(cover.id)
            failedIDs.remove(cover.id)
          } catch {
            guard self.operation == operation, !Task.isCancelled else { return }
            cover.image.image = UIImage(systemName: "photo.badge.exclamationmark")
            failedIDs.insert(cover.id)
          }
          accessibilityValue =
            book.seriesGroupCountText + ", \(loadedIDs.count) covers loaded"
            + (failedIDs.isEmpty ? "" : ", cover loading failed; retry available")
        })
    }
  }
}
