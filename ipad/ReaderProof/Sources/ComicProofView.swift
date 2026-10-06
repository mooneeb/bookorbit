import SwiftUI
import UIKit

struct ComicProofView: View {
  @State private var model: ComicProofModel
  @State private var confirmsDiscard = false
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, file: BookDetailFile) {
    _model = State(initialValue: ComicProofModel(api: api, file: file))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if model.pageCount > 0 {
          ComicCurlView(
            pageCount: model.pageCount, pageIndex: model.pageIndex,
            images: model.images, onTurn: model.didTurn
          )
          .allowsHitTesting(!model.isClosing)
        } else {
          ProgressView("Opening comic…")
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
          Button("Close reader", action: closeReader)
            .frame(minHeight: 44)
            .disabled(model.isClosing)
        }
        .buttonStyle(.plain)
        .font(.body)
        .foregroundStyle(.primary)
        .padding()
      }
      .navigationTitle("Comic reader proof")
      .navigationBarTitleDisplayMode(.inline)
    }
    .task { await model.load() }
    .onDisappear { model.close() }
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
}

private struct ComicCurlView: UIViewControllerRepresentable {
  let pageCount: Int
  let pageIndex: Int
  let images: [Int: UIImage]
  let onTurn: (Int) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(pageCount: pageCount, pageIndex: pageIndex, images: images, onTurn: onTurn)
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
    context.coordinator.update(images: images)
  }

  @MainActor
  final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    let pageCount: Int
    private var currentIndex: Int
    private var images: [Int: UIImage]
    private var pages: [Int: ComicPageController] = [:]
    var onTurn: (Int) -> Void

    init(pageCount: Int, pageIndex: Int, images: [Int: UIImage], onTurn: @escaping (Int) -> Void) {
      self.pageCount = pageCount
      currentIndex = pageIndex
      self.images = images
      self.onTurn = onTurn
    }

    fileprivate func page(at index: Int) -> ComicPageController? {
      guard (0..<pageCount).contains(index), abs(index - currentIndex) <= 1 else { return nil }
      if let cached = pages[index] { return cached }
      let page = ComicPageController(index: index, pageCount: pageCount)
      page.update(images[index])
      pages[index] = page
      return page
    }

    func update(images: [Int: UIImage]) {
      self.images = images
      for (index, page) in pages { page.update(images[index]) }
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
      guard completed, let page = controller.viewControllers?.first as? ComicPageController
      else { return }
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
    loading.text = "Loading comic page…"
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

  func update(_ image: UIImage?) {
    loadViewIfNeeded()
    imageView.image = image
    imageView.isHidden = image == nil
    loading.isHidden = image != nil
  }
}
