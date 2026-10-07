import SwiftUI
import UIKit

struct ComicReaderView: View {
  let api: BookOrbitAPI
  let bookID: Int
  let fileID: Int
  let title: String
  let showsPageControls: Bool
  let onOpenNext: ((ComicReaderTarget) -> Void)?
  @State private var model: ComicReaderModel
  @State private var preferences: ReaderPreferencesModel
  @State private var series: ComicSeriesModel
  @State private var isOpeningNext = false
  @State private var endArmed = false
  @State private var confirmsDiscard = false
  @State private var isNavigating = false
  @State private var isTurning = false
  @State private var isEditingPreferences = false
  @State private var isBrowsingBookmarks = false
  @State private var pageLayout = FixedPageLayout(pageCount: 0, facing: false, singlePrefix: 0)
  @ScaledMetric(relativeTo: .body) private var actionWidth = 150.0
  @Environment(\.dismiss) private var dismiss

  init(
    api: BookOrbitAPI, bookID: Int, file: BookDetailFile, title: String = "Comic reader",
    showsPageControls: Bool = true, onOpenNext: ((ComicReaderTarget) -> Void)? = nil
  ) {
    self.api = api
    self.bookID = bookID
    fileID = file.id
    self.title = title
    self.showsPageControls = showsPageControls
    self.onOpenNext = onOpenNext
    _model = State(initialValue: ComicReaderModel(api: api, file: file))
    _preferences = State(
      initialValue: ReaderPreferencesModel(api: api, fileID: file.id, group: "cbx"))
    _series = State(initialValue: ComicSeriesModel(api: api, bookID: bookID))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if model.pageCount > 0 {
          ComicCurlView(
            pageCount: model.pageCount, pageIndex: model.pageIndex,
            images: model.images, pageErrors: model.pageErrors, onTurn: model.didTurn,
            onTransition: updateTransition, settings: preferences.value.comic,
            animation: preferences.value.pageAnimation, onLayout: updateLayout,
            onVisible: model.showContinuousPages, onBeyondLast: beyondLast,
            facingLayout: preferredFacingLayout
          )
          .allowsHitTesting(!model.isClosing && !isOpeningNext)
        } else if model.error == nil {
          ProgressView("Opening comic…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          Button("Retry opening", action: retryOpening)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        VStack {
          nextComicActions
          if model.pageCount > 0 { Text("Page \(model.pageIndex + 1) of \(model.pageCount)") }
          if let pageError = displayedPageError {
            Text(pageError)
            Button("Retry page", action: model.retryPages).frame(minHeight: 44)
          }
          if let error = model.error { Text(error) }
          if !model.status.isEmpty { Text(model.status) }
          if model.hasUnsavedPosition {
            Button("Retry saving", action: model.retrySaving).frame(minHeight: 44)
            Button("Close without saving") { confirmsDiscard = true }.frame(minHeight: 44)
          }
          if showsPageControls, model.pageCount > 0 {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: actionWidth))]) {
              Button("Previous page", action: previousPage)
                .frame(minHeight: 44)
                .keyboardShortcut(
                  preferences.value.comic.direction == "rtl" ? .rightArrow : .leftArrow,
                  modifiers: []
                )
                .accessibilityIdentifier("comicPreviousPage")
                .disabled(
                  pageLayout.adjacentPage(to: model.pageIndex, delta: -1) == nil || model.isClosing
                    || isTurning)
              Button("Go to page") { isNavigating = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("comicNavigate")
                .disabled(model.isClosing || isTurning)
              Button("Next page", action: nextPage)
                .frame(minHeight: 44)
                .keyboardShortcut(
                  preferences.value.comic.direction == "rtl" ? .leftArrow : .rightArrow,
                  modifiers: []
                )
                .accessibilityIdentifier("comicNextPage")
                .disabled(
                  pageLayout.adjacentPage(to: model.pageIndex, delta: 1) == nil && !canAdvanceOnNext
                    || model.isClosing || isOpeningNext || isTurning)
              Button("Reader settings") { isEditingPreferences = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("readerSettings")
                .disabled(model.isClosing || preferences.isLoading)
              Button {
                isBrowsingBookmarks = true
              } label: {
                Text("Bookmarks").frame(maxWidth: .infinity, minHeight: 44)
                  .contentShape(Rectangle())
              }
              .accessibilityIdentifier("readerBookmarks")
              .disabled(model.isClosing || isTurning)
            }
          }
          Button("Close reader", action: closeReader)
            .frame(minHeight: 44)
            .disabled(model.isClosing)
        }
        .buttonStyle(.plain)
        .font(.body)
        .foregroundStyle(.primary)
        .padding()
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
    }
    .task { await model.load() }
    .task { if showsPageControls { await preferences.load() } }
    .task { if onOpenNext != nil { await series.load() } }
    .task(id: endArmKey) { await armNext() }
    .onChange(of: preferences.value.comic.scrollMode, initial: true) { (_: String, mode: String) in
      model.configureContinuous(mode != "paginated")
    }
    .onDisappear {
      if !isNavigating && !isEditingPreferences && !isBrowsingBookmarks {
        model.close()
        preferences.close()
        series.close()
      }
    }
    .disabled(isOpeningNext)
    .fullScreenCover(isPresented: $isBrowsingBookmarks) {
      ReaderBookmarksView(
        api: api, bookID: bookID, fileID: fileID, currentPage: model.pageIndex + 1,
        pageCount: model.pageCount, onSelect: model.didTurn)
    }
    .fullScreenCover(isPresented: $isEditingPreferences) {
      ReaderPreferencesView(model: preferences)
    }
    .fullScreenCover(isPresented: $isNavigating) {
      ReaderPageNavigationView(
        currentPage: model.pageIndex + 1, pageCount: model.pageCount,
        identifierPrefix: "comic", onNavigate: model.didTurn)
    }
    .alert("Discard unsaved position?", isPresented: $confirmsDiscard) {
      Button("Keep reading", role: .cancel) {}
      Button("Discard and close", role: .destructive, action: dismiss.callAsFunction)
    } message: {
      Text("The next session will resume at the last saved position.")
    }
  }

  @ViewBuilder private var nextComicActions: some View {
    if isOpeningNext { ProgressView("Opening next comic…") }
    if atLastUnit, onOpenNext != nil {
      if let next = series.next {
        Button(action: openNext) {
          Text("Open next comic: \(next.title ?? "Untitled book")")
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.accessibilityIdentifier("comicOpenNextBook")
          .disabled(isOpeningNext || model.isClosing || isTurning)
        if canAdvanceOnNext { Text("Turn past the last page to open the next comic.") }
      }
      if let error = series.error {
        Text(error).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("comicNextBookError")
        if !series.hasLoaded {
          Button {
            Task { await series.load() }
          } label: {
            Text("Retry next comic").frame(minHeight: 44).contentShape(Rectangle())
          }.accessibilityIdentifier("comicRetryNextBook")
            .disabled(series.isLoading || isOpeningNext)
        }
      }
    }
  }

  private var beyondLast: (() -> Void)? {
    guard onOpenNext != nil else { return nil }
    return nextPage
  }

  private func armNext() async {
    endArmed = false
    guard atLastUnit, preferences.value.comic.autoAdvance,
      preferences.value.comic.scrollMode == "paginated", series.next != nil, onOpenNext != nil
    else { return }
    do {
      try await Task.sleep(for: .milliseconds(1500))
      try Task.checkCancellation()
      endArmed = true
    } catch {}
  }

  private func closeReader() {
    Task { if await model.prepareToClose() { dismiss() } }
  }

  private func retryOpening() {
    Task { await model.load() }
  }

  private var displayedPageError: String? {
    pageLayout.pages(in: pageLayout.unit(for: model.pageIndex)).compactMap { model.pageErrors[$0] }
      .first
  }

  private func updateLayout(_ layout: FixedPageLayout) {
    pageLayout = layout
    model.configureLayout(layout)
  }

  private func updateTransition(_ active: Bool) {
    isTurning = active
    model.noteTransition(active)
  }

  private var preferredFacingLayout: FixedPageLayout? {
    guard preferences.value.comic.widePageSingletonMode == "auto" else { return nil }
    return preferences.value.comic.spreadAlignment == "shifted"
      ? model.shiftedFacingLayout : model.normalFacingLayout
  }

  private func previousPage() {
    if let page = pageLayout.adjacentPage(to: model.pageIndex, delta: -1) {
      model.didTurn(to: page)
    }
  }
  private func nextPage() {
    guard !isOpeningNext, !model.isClosing, !isTurning else { return }
    if let page = pageLayout.adjacentPage(to: model.pageIndex, delta: 1) {
      model.didTurn(to: page)
    } else if canAdvanceOnNext {
      openNext()
    }
  }

  private var atLastUnit: Bool {
    model.pageCount > 0 && pageLayout.adjacentPage(to: model.pageIndex, delta: 1) == nil
  }

  private var canAdvanceOnNext: Bool {
    endArmed && atLastUnit && preferences.value.comic.autoAdvance
      && preferences.value.comic.scrollMode == "paginated" && series.next != nil
      && onOpenNext != nil
  }

  private var endArmKey: ComicEndArmKey {
    ComicEndArmKey(
      page: model.pageIndex, total: model.pageCount, scroll: preferences.value.comic.scrollMode,
      enabled: preferences.value.comic.autoAdvance, nextBookID: series.next?.bookId,
      last: atLastUnit)
  }

  private func openNext() {
    guard !isOpeningNext, !isTurning, series.next != nil, let onOpenNext else { return }
    isOpeningNext = true
    Task {
      defer { isOpeningNext = false }
      model.didTurn(to: model.pageCount - 1)
      guard await model.prepareToClose(), let target = await series.target() else { return }
      onOpenNext(target)
    }
  }
}

private struct ComicEndArmKey: Equatable {
  let page: Int
  let total: Int
  let scroll: String
  let enabled: Bool
  let nextBookID: Int?
  let last: Bool
}

private struct ComicCurlView: View {
  let pageCount: Int
  let pageIndex: Int
  let images: [Int: UIImage]
  let pageErrors: [Int: String]
  let onTurn: (Int) -> Void
  let onTransition: (Bool) -> Void
  var settings = CbxReaderSettings.readerDefault
  var animation = ReaderTurnAnimation.curl
  var onLayout: (FixedPageLayout) -> Void = { _ in }
  var onVisible: (Set<Int>) -> Void = { _ in }
  var onBeyondLast: (() -> Void)?
  var facingLayout: FixedPageLayout?

  var body: some View {
    let continuous = settings.scrollMode != "paginated"
    FixedReaderSurface(
      pageCount: pageCount, pageIndex: pageIndex, animation: animation,
      identifier: "comicReader",
      facingMode: !continuous && settings.viewMode == "two-page" ? "auto" : "never",
      singlePrefix: settings.spreadAlignment == "shifted" ? 2 : 1,
      forceFacing: settings.forceTwoPage, minimumFacingAspect: 0,
      continuousAxis: continuous ? "vertical" : nil, rightToLeft: settings.direction == "rtl",
      spreadGap: CGFloat(settings.spreadGap), pageGap: settings.scrollMode == "long-strip" ? 0 : 12,
      pageHeight: { index, size in
        if settings.fitMode == "fit-page" || settings.fitMode == "fit-height" { return size.height }
        guard let image = images[index], image.size.width > 0 else { return size.height }
        return settings.fitMode == "actual"
          ? image.size.height : size.width * image.size.height / image.size.width
      },
      makePage: { ComicPageController(index: $0, pageCount: pageCount) },
      refreshPage: { controller, index in
        (controller as? ComicPageController)?.update(
          images[index], error: pageErrors[index], settings: settings)
      }, onTurn: onTurn, onLayout: onLayout, onTransition: onTransition, onVisible: onVisible,
      onBeyondLast: onBeyondLast, facingLayout: facingLayout, usesVirtualBlanks: true
    )
  }
}

private final class ComicPageController: UIViewController, UIScrollViewDelegate {
  let index: Int
  private let pageCount: Int
  private let imageView = UIImageView()
  private let scroll = UIScrollView()
  private let loading = UILabel()
  private var settings = CbxReaderSettings.readerDefault
  private var previousSize = CGSize.zero
  private var needsImageLayout = true

  init(index: Int, pageCount: Int) {
    self.index = index
    self.pageCount = pageCount
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func loadView() {
    view = UIView()
    view.backgroundColor = .systemBackground
    imageView.contentMode = .scaleAspectFit
    imageView.isAccessibilityElement = true
    imageView.accessibilityLabel = "Comic page \(index + 1) of \(pageCount)"
    imageView.accessibilityIdentifier = "comicPage\(index + 1)"
    scroll.delegate = self
    scroll.minimumZoomScale = 1
    scroll.maximumZoomScale = 4
    scroll.bounces = false
    scroll.bouncesZoom = false
    scroll.addSubview(imageView)
    loading.font = .preferredFont(forTextStyle: .body)
    loading.adjustsFontForContentSizeCategory = true
    loading.textColor = .label
    loading.backgroundColor = .systemBackground
    loading.numberOfLines = 0
    loading.textAlignment = .center
    for child in [scroll, loading] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
      NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        child.topAnchor.constraint(equalTo: view.topAnchor),
        child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard needsImageLayout || previousSize != scroll.bounds.size, let image = imageView.image,
      image.size.width > 0, image.size.height > 0, scroll.bounds.width > 0, scroll.bounds.height > 0
    else { return }
    previousSize = scroll.bounds.size
    needsImageLayout = false
    scroll.setZoomScale(1, animated: false)
    let widthScale = scroll.bounds.width / image.size.width
    let heightScale = scroll.bounds.height / image.size.height
    let scale: CGFloat
    switch settings.fitMode {
    case "fit-width": scale = widthScale
    case "fit-height": scale = heightScale
    case "actual": scale = 1
    default: scale = min(widthScale, heightScale)
    }
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    imageView.frame = CGRect(origin: .zero, size: size)
    scroll.contentSize = size
    scroll.contentOffset = .zero
    centerImage()
    updatePanGesture()
  }

  func update(_ image: UIImage?, error: String?, settings: CbxReaderSettings) {
    loadViewIfNeeded()
    if imageView.image !== image || self.settings != settings { needsImageLayout = true }
    self.settings = settings
    imageView.image = image
    scroll.isHidden = image == nil
    scroll.backgroundColor =
      settings.bgColor == "white" ? .white : settings.bgColor == "gray" ? .darkGray : .black
    loading.text = error == nil ? "Loading comic page…" : "Comic page could not be loaded."
    loading.isHidden = image != nil
    view.setNeedsLayout()
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    centerImage()
    updatePanGesture()
  }

  private func updatePanGesture() {
    scroll.panGestureRecognizer.isEnabled =
      settings.scrollMode == "paginated" || scroll.zoomScale > 1
      || scroll.contentSize.width > scroll.bounds.width + 1
  }

  private func centerImage() {
    scroll.contentInset = UIEdgeInsets(
      top: max(0, (scroll.bounds.height - imageView.frame.height) / 2),
      left: max(0, (scroll.bounds.width - imageView.frame.width) / 2), bottom: 0, right: 0)
  }
}
