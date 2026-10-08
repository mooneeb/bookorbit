import UIKit

enum BookTableAction {
  case edit(book: BookCard, column: BookTableColumnDefinition)
  case toggleLock(book: BookCard, field: String)
  case toggleAllLocks(book: BookCard)
  case details(book: BookCard)
  case quickView(book: BookCard)
  case read(book: BookCard, fileID: Int)
  case cover(book: BookCard)
  case editMetadata(book: BookCard)
  case refreshMetadata(book: BookCard)
  case collections(book: BookCard)
  case delete(book: BookCard)
  case move(book: BookCard)
  case authors(name: String)
  case series(id: Int, name: String)
  case quickFilter(rule: Rule)
  case sort(field: String)
  case sortDirection(field: String, descending: Bool)
  case clearSort(field: String)
}

@MainActor struct BookTableColumnRenderer {
  let api: BookOrbitAPI
  let customFields: [CustomMetadataFieldSummary]
  let canEditMetadata: Bool
  let canRead: Bool
  var canDeleteBooks = false
  var isBusy = false
  var sort = "title"
  var descending = false
  var openSeriesGroup: @MainActor (BookCard) -> Void = { _ in }
  var openSeriesBook: @MainActor (Int) -> Void = { _ in }
  let action: @MainActor (BookTableAction) -> Void

  func makeHeader(column: String) -> UIView {
    guard let definition = BookTableColumnSchema.definition(id: column, customFields: customFields)
    else {
      return label(column, header: true)
    }
    let image: String?
    switch column {
    case "cover": image = "photo"
    case "read": image = "book"
    case "lockRow": image = "lock"
    case "actions": image = "ellipsis"
    default: image = nil
    }
    let menu = makeHeaderMenu(column: column)
    if menu.children.isEmpty {
      if let image {
        let view = UIImageView(image: UIImage(systemName: image))
        view.contentMode = .center
        view.tintColor = .label
        view.isAccessibilityElement = true
        view.accessibilityLabel = definition.label
        view.accessibilityTraits = .header
        return view
      }
      return label(definition.label, header: true)
    }
    let control = button(image == nil ? definition.label : "", image: image, action: {})
    control.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    control.menu = menu
    control.showsMenuAsPrimaryAction = true
    control.accessibilityLabel = "\(definition.label) column options"
    control.accessibilityTraits.insert(.header)
    control.accessibilityValue =
      definition.sortField == sort ? (descending ? "Descending" : "Ascending") : "Not sorted"
    control.accessibilityIdentifier = "tableSort\(column)"
    return control
  }

  func makeCell(book: BookCard, column: String) -> UIView {
    if book.collapsedSeries != nil {
      return BookTableSeriesGroupPresentation.makeCell(
        api: api, book: book, column: column, isBusy: isBusy,
        openSeries: { openSeriesGroup(book) }, openBook: openSeriesBook)
    }
    let title = book.title ?? "Untitled book"
    if column == "cover" {
      return BookTableCoverButton(api: api, book: book) { action(.cover(book: book)) }
    }
    if column == "actions" {
      let control = button("", image: "ellipsis", action: {})
      control.menu = makeMenu(book: book)
      control.showsMenuAsPrimaryAction = true
      control.accessibilityLabel = "Actions for \(title)"
      control.accessibilityIdentifier = "tableActions\(book.id)"
      return control
    }
    if column == "read" {
      let files = BookTableColumnSchema.contentFiles(book)
      guard canRead, let file = files.first(where: { $0.role == "primary" }) ?? files.first else {
        let view = label(canRead ? "No files" : "Unavailable")
        view.accessibilityIdentifier = "tableRead\(book.id)"
        return view
      }
      let isAudio = AudioStreamFormat.mimeTypes[file.format?.lowercased() ?? ""] != nil
      let control = button(isAudio ? "Listen" : "Read", image: nil) {
        action(.read(book: book, fileID: file.id))
      }
      if files.count > 1 {
        control.menu = UIMenu(children: files.map { fileAction(book: book, file: $0) })
        control.showsMenuAsPrimaryAction = true
      }
      control.accessibilityLabel =
        files.count > 1
        ? "Choose format for \(title)" : "\(isAudio ? "Listen to" : "Read") \(title)"
      control.accessibilityIdentifier = "tableRead\(book.id)"
      return control
    }
    if column == "lockRow" {
      let locked = Set(MetadataVocabulary.lockFields).isSubset(of: Set(book.lockedFields))
      let control = button("", image: book.lockedFields.isEmpty ? "lock.open" : "lock") {
        action(.toggleAllLocks(book: book))
      }
      control.isEnabled = canEditMetadata && !isBusy
      control.accessibilityLabel = "\(locked ? "Unlock" : "Lock") all metadata for \(title)"
      control.accessibilityValue = BookTableColumnSchema.text(book, column: column)
      control.accessibilityIdentifier = "tableRowLock\(book.id)"
      return control
    }
    let text = BookTableColumnSchema.text(book, column: column)
    guard let definition = BookTableColumnSchema.definition(id: column, customFields: customFields)
    else {
      return label(text)
    }
    let editable = canEditMetadata && BookTableColumnSchema.canEdit(book, definition: definition)
    let content: UIView
    if editable {
      let control = button(text, image: nil) { action(.edit(book: book, column: definition)) }
      control.accessibilityLabel = "Edit \(definition.label) for \(title)"
      control.accessibilityValue = text
      control.accessibilityIdentifier = "tableCell\(book.id)_\(column)"
      content = control
    } else {
      let view = label(text)
      view.accessibilityLabel = "\(definition.label): \(text)"
      view.accessibilityIdentifier = "tableCell\(book.id)_\(column)"
      content = view
    }
    var controls: [UIButton] = []
    let navigation = cellNavigation(book: book, column: column)
    if !navigation.isEmpty {
      let control = button("", image: "arrow.up.forward", action: {})
      control.menu = UIMenu(children: navigation)
      control.showsMenuAsPrimaryAction = true
      control.accessibilityLabel = "Open \(definition.label.lowercased()) actions for \(title)"
      control.accessibilityIdentifier = "tableOpen\(book.id)_\(column)"
      controls.append(control)
    }
    guard let field = definition.lockField else {
      return controls.isEmpty ? content : BookTableValueView(value: content, controls: controls)
    }
    let locked = book.lockedFields.contains(field)
    guard canEditMetadata else {
      if locked { content.accessibilityValue = "\(text), locked" }
      return controls.isEmpty ? content : BookTableValueView(value: content, controls: controls)
    }
    let control = button("", image: locked ? "lock" : "lock.open") {
      action(.toggleLock(book: book, field: field))
    }
    control.isEnabled = !isBusy
    control.accessibilityLabel =
      "\(locked ? "Unlock" : "Lock") \(definition.label.lowercased()) for \(title)"
    control.accessibilityValue = locked ? "Locked" : "Unlocked"
    control.accessibilityIdentifier = "tableLock\(book.id)_\(column)"
    controls.append(control)
    return BookTableValueView(value: content, controls: controls)
  }

  func makeHeaderMenu(column: String) -> UIMenu {
    var children: [UIMenuElement] = []
    if let field = BookTableColumnSchema.definition(id: column, customFields: customFields)?
      .sortField
    {
      children.append(
        menuAction("Sort ascending", image: "arrow.up") {
          action(.sortDirection(field: field, descending: false))
        })
      children.append(
        menuAction("Sort descending", image: "arrow.down") {
          action(.sortDirection(field: field, descending: true))
        })
      children.append(menuAction("Clear sort", image: "xmark") { action(.clearSort(field: field)) })
    }
    for (key, label) in headerFilters(column: column) {
      if let rule = quickFilter(column: column, key: key) {
        children.append(
          menuAction(label, image: "line.3.horizontal.decrease") {
            action(.quickFilter(rule: rule))
          })
      }
    }
    return UIMenu(children: children)
  }

  func makeMenu(book: BookCard) -> UIMenu {
    if book.collapsedSeries != nil {
      return BookTableSeriesGroupPresentation.makeMenu(
        book: book, isBusy: isBusy, openSeries: { openSeriesGroup(book) }, openBook: openSeriesBook)
    }
    var children: [UIMenuElement] = [
      menuAction("Quick view", image: "book") { action(.quickView(book: book)) },
      menuAction("Book details", image: "info.circle") { action(.details(book: book)) },
      menuAction("View cover", image: "photo") { action(.cover(book: book)) },
      menuAction("Manage collections", image: "folder.badge.plus") {
        action(.collections(book: book))
      },
    ]
    if canRead {
      let files = BookTableColumnSchema.contentFiles(book)
      if !files.isEmpty {
        children.append(
          UIMenu(title: "Read or listen", children: files.map { fileAction(book: book, file: $0) }))
      }
    }
    if canEditMetadata {
      children.append(contentsOf: [
        menuAction("Edit metadata", image: "pencil") { action(.editMetadata(book: book)) },
        menuAction("Refresh metadata", image: "arrow.clockwise") {
          action(.refreshMetadata(book: book))
        },
        menuAction("Move to library", image: "folder") { action(.move(book: book)) },
      ])
    }
    if canDeleteBooks {
      let deletion = UIAction(
        title: "Delete book", image: UIImage(systemName: "trash"),
        attributes: isBusy ? [.destructive, .disabled] : .destructive
      ) { _ in action(.delete(book: book)) }
      children.append(deletion)
    }
    return UIMenu(title: book.title ?? "Untitled book", children: children)
  }

  func fittingWidth(book: BookCard, column: String) -> CGFloat {
    if book.collapsedSeries != nil {
      return max(
        CGFloat(
          BookTableColumnSchema.definition(id: column, customFields: customFields)?.minimumWidth
            ?? 44),
        BookTableSeriesGroupPresentation.fittingWidth(book: book, column: column))
    }
    guard let definition = BookTableColumnSchema.definition(id: column, customFields: customFields)
    else { return 160 }
    if ["cover", "read", "actions", "lockRow"].contains(column) {
      return CGFloat(definition.defaultWidth)
    }
    let value = BookTableColumnSchema.text(book, column: column) as NSString
    let measured = value.size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .body)])
      .width
    let header = (definition.label as NSString).size(withAttributes: [
      .font: UIFont.preferredFont(forTextStyle: .headline)
    ]).width
    let padding: CGFloat =
      (canEditMetadata && definition.lockField != nil ? 52 : 12)
      + (cellNavigation(book: book, column: column).isEmpty ? 0 : 44)
    return min(800, max(CGFloat(definition.minimumWidth), max(measured + padding, header + 12)))
  }

  private func label(_ text: String, header: Bool = false) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .preferredFont(forTextStyle: header ? .headline : .body)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .label
    label.numberOfLines = 0
    if header { label.accessibilityTraits = .header }
    return label
  }

  private func button(_ title: String, image: String?, action: @escaping @MainActor () -> Void)
    -> UIButton
  {
    let control = BookTableButton(type: .system)
    control.setTitle(title, for: .normal)
    control.setTitleColor(.label, for: .normal)
    if let image { control.setImage(UIImage(systemName: image), for: .normal) }
    control.tintColor = .label
    control.titleLabel?.font = .preferredFont(forTextStyle: .body)
    control.titleLabel?.adjustsFontForContentSizeCategory = true
    control.titleLabel?.numberOfLines = 0
    control.titleLabel?.lineBreakMode = .byWordWrapping
    control.contentHorizontalAlignment = .leading
    control.isEnabled = !isBusy
    control.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return control
  }

  private func menuAction(_ title: String, image: String, action: @escaping @MainActor () -> Void)
    -> UIAction
  {
    UIAction(title: title, image: UIImage(systemName: image), attributes: isBusy ? .disabled : []) {
      _ in action()
    }
  }

  private func fileAction(book: BookCard, file: BookFileRef) -> UIAction {
    let isAudio = AudioStreamFormat.mimeTypes[file.format?.lowercased() ?? ""] != nil
    return menuAction(
      "\(isAudio ? "Listen" : "Read") \(file.format?.uppercased() ?? "file")",
      image: isAudio ? "play" : "book"
    ) {
      action(.read(book: book, fileID: file.id))
    }
  }

  private func cellNavigation(book: BookCard, column: String) -> [UIMenuElement] {
    switch column {
    case "title":
      return [menuAction("Book details", image: "info.circle") { action(.details(book: book)) }]
    case "seriesName":
      guard let id = book.seriesId, let name = book.seriesName else { return [] }
      return [
        menuAction("Open series", image: "books.vertical") { action(.series(id: id, name: name)) }
      ]
    case "authors":
      return book.authors.map { name in
        menuAction("Browse \(name)", image: "person") { action(.authors(name: name)) }
      }
    case "genres", "tags":
      let names = column == "genres" ? book.genres : book.tags
      return names.map { name in
        menuAction("Filter by \(name)", image: "line.3.horizontal.decrease") {
          action(
            .quickFilter(
              rule: .init(
                type: "rule", field: column == "genres" ? "genre" : "tag", operator: "includesAny",
                value: .strings([name]))))
        }
      }
    default: return []
    }
  }

  private func headerFilters(column: String) -> [(String, String)] {
    if column == "cover" {
      return [
        ("present", "With covers"), ("missing", "Missing covers"),
        ("missingAudio", "Missing audio covers"),
      ]
    }
    if column == "format" { return [("present", "Present files"), ("missing", "Missing files")] }
    if [
      "title", "seriesName", "publisher", "language", "isbn13", "subtitle", "authors", "genres",
      "tags", "readStatus", "rating", "pageCount", "publishedDate", "publishedYear",
      "metadataScore",
    ].contains(column) {
      return [("present", "With values"), ("missing", "Empty rows")]
    }
    return []
  }

  private func quickFilter(column: String, key: String) -> Rule? {
    if column == "format" {
      return .init(
        type: "rule", field: "fileAvailability",
        operator: key == "missing" ? "isMissing" : "isPresent")
    }
    if column == "cover" {
      return .init(
        type: "rule", field: key == "missingAudio" ? "audioCover" : "cover",
        operator: key == "present" ? "isPresent" : "isMissing")
    }
    let fields = [
      "title": "title", "seriesName": "series", "publisher": "publisher", "language": "language",
      "isbn13": "isbn", "subtitle": "description", "authors": "author", "genres": "genre",
      "tags": "tag", "readStatus": "readStatus", "rating": "rating", "pageCount": "pageCount",
      "publishedDate": "publishedDate", "publishedYear": "publishedYear",
      "metadataScore": "metadataScore",
    ]
    guard let field = fields[column] else { return nil }
    return .init(type: "rule", field: field, operator: key == "missing" ? "isEmpty" : "isNotEmpty")
  }
}

private final class BookTableButton: UIButton {
  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let measured = super.sizeThatFits(size)
    let text =
      titleLabel?.sizeThatFits(CGSize(width: max(1, size.width), height: .greatestFiniteMagnitude))
      ?? .zero
    return CGSize(
      width: min(size.width, max(44, measured.width)),
      height: max(44, max(measured.height, text.height + 8)))
  }
}

private final class BookTableValueView: UIView {
  private let value: UIView
  private let controls: [UIButton]

  init(value: UIView, controls: [UIButton]) {
    self.value = value
    self.controls = controls
    super.init(frame: .zero)
    addSubview(value)
    controls.forEach(addSubview)
  }

  required init?(coder: NSCoder) { return nil }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let horizontal = size.width >= 120 + CGFloat(max(0, controls.count - 1) * 44)
    let width = horizontal ? max(1, size.width - CGFloat(controls.count * 44) - 4) : size.width
    let height = value.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    return CGSize(
      width: size.width,
      height: horizontal ? max(44, height) : height + CGFloat(controls.count * 44))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if bounds.width >= 120 + CGFloat(max(0, controls.count - 1) * 44) {
      value.frame = CGRect(
        x: 0, y: 0, width: max(1, bounds.width - CGFloat(controls.count * 44) - 4),
        height: bounds.height)
      for (index, control) in controls.enumerated() {
        control.frame = CGRect(
          x: bounds.width - CGFloat((controls.count - index) * 44), y: (bounds.height - 44) / 2,
          width: 44, height: 44)
      }
    } else {
      value.frame = CGRect(
        x: 0, y: 0, width: bounds.width,
        height: max(0, bounds.height - CGFloat(controls.count * 44)))
      for (index, control) in controls.enumerated() {
        control.frame = CGRect(
          x: (bounds.width - 44) / 2, y: bounds.height - CGFloat((controls.count - index) * 44),
          width: 44, height: 44)
      }
    }
  }
}

private final class BookTableCoverButton: UIButton {
  private let api: BookOrbitAPI
  private let book: BookCard
  private var loading: Task<Void, Never>?
  private var imageLoaded = false
  private var operation = UUID()

  init(api: BookOrbitAPI, book: BookCard, action: @escaping @MainActor () -> Void) {
    self.api = api
    self.book = book
    super.init(frame: .zero)
    tintColor = .label
    setImage(UIImage(systemName: "book.closed"), for: .normal)
    imageView?.contentMode = .scaleAspectFit
    accessibilityLabel = "View cover for \(book.title ?? "Untitled book")"
    accessibilityIdentifier = "tableCover\(book.id)"
    accessibilityValue = book.hasCover ? "Loading cover" : "No cover available"
    addAction(UIAction { _ in action() }, for: .touchUpInside)
  }

  required init?(coder: NSCoder) { return nil }

  override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: 56) }

  override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
    contentRect.insetBy(dx: 2, dy: 2)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      operation = UUID()
      loading?.cancel()
      loading = nil
    } else if book.hasCover && !imageLoaded {
      load()
    }
  }

  private func load() {
    guard loading == nil else { return }
    let id = UUID()
    operation = id
    loading = Task { [weak self] in
      guard let self else { return }
      defer { if operation == id { self.loading = nil } }
      do {
        let namespace = try await api.imageNamespace()
        let image = try await CoverPreviewLoader.shared.thumbnail(
          api: api, bookID: book.id, version: book.coverVersion, namespace: namespace)
        try Task.checkCancellation()
        guard operation == id else { return }
        setImage(image, for: .normal)
        imageLoaded = true
        accessibilityValue = "Cover available"
      } catch {
        guard operation == id, !Task.isCancelled else { return }
        setImage(UIImage(systemName: "photo.badge.exclamationmark"), for: .normal)
        accessibilityValue = "Could not load cover. Open cover preview to retry."
      }
    }
  }
}
