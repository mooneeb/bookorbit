import SwiftUI
import UIKit

struct ComicReaderView: View {
  let title: String
  let showsPageControls: Bool
  @State private var model: ComicReaderModel
  @State private var preferences: ReaderPreferencesModel
  @State private var confirmsDiscard = false
  @State private var isNavigating = false
  @State private var isTurning = false
  @State private var isEditingPreferences = false
  @ScaledMetric(relativeTo: .body) private var actionWidth = 150.0
  @Environment(\.dismiss) private var dismiss

  init(
    api: BookOrbitAPI, file: BookDetailFile, title: String = "Comic reader",
    showsPageControls: Bool = true
  ) {
    self.title = title
    self.showsPageControls = showsPageControls
    _model = State(initialValue: ComicReaderModel(api: api, file: file))
    _preferences = State(
      initialValue: ReaderPreferencesModel(api: api, fileID: file.id, group: "cbx"))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if model.pageCount > 0 {
          ComicCurlView(
            pageCount: model.pageCount, pageIndex: model.pageIndex,
            images: model.images, pageErrors: model.pageErrors, onTurn: model.didTurn,
            onTransition: { isTurning = $0 }, settings: preferences.value.comic,
            animation: preferences.value.pageAnimation
          )
          .allowsHitTesting(!model.isClosing)
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
          if model.pageCount > 0 { Text("Page \(model.pageIndex + 1) of \(model.pageCount)") }
          if let pageError = model.pageErrors[model.pageIndex] {
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
                .keyboardShortcut(.leftArrow, modifiers: [])
                .accessibilityIdentifier("comicPreviousPage")
                .disabled(model.pageIndex == 0 || model.isClosing || isTurning)
              Button("Go to page") { isNavigating = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("comicNavigate")
                .disabled(model.isClosing || isTurning)
              Button("Next page", action: nextPage)
                .frame(minHeight: 44)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .accessibilityIdentifier("comicNextPage")
                .disabled(model.pageIndex + 1 == model.pageCount || model.isClosing || isTurning)
              Button("Reader settings") { isEditingPreferences = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("readerSettings")
                .disabled(model.isClosing || preferences.isLoading)
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
    .onDisappear {
      if !isNavigating && !isEditingPreferences {
        model.close()
        preferences.close()
      }
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

  private func closeReader() {
    Task { if await model.prepareToClose() { dismiss() } }
  }

  private func retryOpening() {
    Task { await model.load() }
  }

  private func previousPage() { model.didTurn(to: model.pageIndex - 1) }
  private func nextPage() { model.didTurn(to: model.pageIndex + 1) }
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let effectiveAnimation = reduceMotion ? ReaderTurnAnimation.none : animation
    NativePagedView(
      pageCount: pageCount, pageIndex: pageIndex, animation: effectiveAnimation,
      identifier: "comicReader",
      makePage: { ComicPageController(index: $0, pageCount: pageCount) },
      refreshPage: { controller, index in
        (controller as? ComicPageController)?.update(
          images[index], error: pageErrors[index], settings: settings)
      }, onTurn: onTurn, onTransition: onTransition
    )
    .id(effectiveAnimation)
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
  func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

  private func centerImage() {
    scroll.contentInset = UIEdgeInsets(
      top: max(0, (scroll.bounds.height - imageView.frame.height) / 2),
      left: max(0, (scroll.bounds.width - imageView.frame.width) / 2), bottom: 0, right: 0)
  }
}
