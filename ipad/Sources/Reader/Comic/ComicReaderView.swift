import SwiftUI
import UIKit

struct ComicReaderView: View {
  let title: String
  let showsPageControls: Bool
  @State private var model: ComicReaderModel
  @State private var confirmsDiscard = false
  @State private var isNavigating = false
  @State private var isTurning = false
  @ScaledMetric(relativeTo: .body) private var actionWidth = 150.0
  @Environment(\.dismiss) private var dismiss

  init(
    api: BookOrbitAPI, file: BookDetailFile, title: String = "Comic reader",
    showsPageControls: Bool = true
  ) {
    self.title = title
    self.showsPageControls = showsPageControls
    _model = State(initialValue: ComicReaderModel(api: api, file: file))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if model.pageCount > 0 {
          ComicCurlView(
            pageCount: model.pageCount, pageIndex: model.pageIndex,
            images: model.images, pageErrors: model.pageErrors, onTurn: model.didTurn,
            onTransition: { isTurning = $0 }
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
    .onDisappear { if !isNavigating { model.close() } }
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

private struct ComicCurlView: UIViewControllerRepresentable {
  let pageCount: Int
  let pageIndex: Int
  let images: [Int: UIImage]
  let pageErrors: [Int: String]
  let onTurn: (Int) -> Void
  let onTransition: (Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      pageCount: pageCount, pageIndex: pageIndex, images: images,
      pageErrors: pageErrors, onTurn: onTurn, onTransition: onTransition)
  }

  func makeUIViewController(context: Context) -> UIPageViewController {
    let controller = UIPageViewController(
      transitionStyle: .pageCurl, navigationOrientation: .horizontal,
      options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
    controller.isDoubleSided = false
    controller.dataSource = context.coordinator
    controller.delegate = context.coordinator
    controller.view.accessibilityIdentifier = "comicReader"
    controller.view.backgroundColor = .systemBackground
    if let page = context.coordinator.page(at: pageIndex) {
      controller.setViewControllers([page], direction: .forward, animated: false)
    }
    return controller
  }

  func updateUIViewController(_ controller: UIPageViewController, context: Context) {
    context.coordinator.onTurn = onTurn
    context.coordinator.onTransition = onTransition
    context.coordinator.update(images: images, pageErrors: pageErrors)
    context.coordinator.show(pageIndex, in: controller)
  }

  @MainActor
  final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    let pageCount: Int
    private var currentIndex: Int
    private var requestedIndex: Int
    private var isTransitioning = false
    private var images: [Int: UIImage]
    private var pageErrors: [Int: String]
    private var pages: [Int: ComicPageController] = [:]
    var onTurn: (Int) -> Void
    var onTransition: (Bool) -> Void

    init(
      pageCount: Int, pageIndex: Int, images: [Int: UIImage],
      pageErrors: [Int: String], onTurn: @escaping (Int) -> Void,
      onTransition: @escaping (Bool) -> Void
    ) {
      self.pageCount = pageCount
      currentIndex = pageIndex
      requestedIndex = pageIndex
      self.images = images
      self.pageErrors = pageErrors
      self.onTurn = onTurn
      self.onTransition = onTransition
    }

    fileprivate func page(at index: Int) -> ComicPageController? {
      guard (0..<pageCount).contains(index), abs(index - currentIndex) <= 1 else { return nil }
      if let cached = pages[index] { return cached }
      let page = ComicPageController(index: index, pageCount: pageCount)
      page.update(images[index], error: pageErrors[index])
      pages[index] = page
      return page
    }

    func update(images: [Int: UIImage], pageErrors: [Int: String]) {
      self.images = images
      self.pageErrors = pageErrors
      for (index, page) in pages { page.update(images[index], error: pageErrors[index]) }
    }

    func show(_ index: Int, in controller: UIPageViewController) {
      guard (0..<pageCount).contains(index) else { return }
      requestedIndex = index
      guard index != currentIndex, !isTransitioning else { return }
      let direction: UIPageViewController.NavigationDirection =
        index > currentIndex ? .forward : .reverse
      currentIndex = index
      pages = pages.filter { abs($0.key - currentIndex) <= 1 }
      if let page = page(at: index) {
        controller.setViewControllers([page], direction: direction, animated: false)
      }
    }

    func pageViewController(
      _ controller: UIPageViewController,
      willTransitionTo pendingViewControllers: [UIViewController]
    ) {
      isTransitioning = true
      onTransition(true)
    }

    func pageViewController(
      _ controller: UIPageViewController, viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
      guard let page = viewController as? ComicPageController else { return nil }
      return self.page(at: page.index - 1)
    }

    func pageViewController(
      _ controller: UIPageViewController, viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
      guard let page = viewController as? ComicPageController else { return nil }
      return self.page(at: page.index + 1)
    }

    func pageViewController(
      _ controller: UIPageViewController, didFinishAnimating finished: Bool,
      previousViewControllers: [UIViewController], transitionCompleted completed: Bool
    ) {
      isTransitioning = false
      onTransition(false)
      guard completed, let page = controller.viewControllers?.first as? ComicPageController
      else {
        show(requestedIndex, in: controller)
        return
      }
      currentIndex = page.index
      pages = pages.filter { abs($0.key - currentIndex) <= 1 }
      onTurn(currentIndex)
    }

    func pageViewController(
      _ controller: UIPageViewController, spineLocationFor orientation: UIInterfaceOrientation
    ) -> UIPageViewController.SpineLocation { .min }
  }
}

private final class ComicPageController: UIViewController {
  let index: Int
  private let pageCount: Int
  private let imageView = UIImageView()
  private let loading = UILabel()

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
    loading.font = .preferredFont(forTextStyle: .body)
    loading.adjustsFontForContentSizeCategory = true
    loading.textColor = .label
    loading.backgroundColor = .systemBackground
    loading.numberOfLines = 0
    loading.textAlignment = .center
    for child in [imageView, loading] {
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

  func update(_ image: UIImage?, error: String?) {
    loadViewIfNeeded()
    imageView.image = image
    imageView.isHidden = image == nil
    loading.text = error == nil ? "Loading comic page…" : "Comic page could not be loaded."
    loading.isHidden = image != nil
  }
}
