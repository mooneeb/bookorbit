import PDFKit
import SwiftUI
import UIKit

struct PDFCurlView: UIViewControllerRepresentable {
  let document: PDFDocument
  let pageIndex: Int
  let onTurn: (Int) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(document: document, pageIndex: pageIndex, onTurn: onTurn)
  }

  func makeUIViewController(context: Context) -> UIPageViewController {
    let controller = UIPageViewController(
      transitionStyle: .pageCurl, navigationOrientation: .horizontal,
      options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
    controller.isDoubleSided = false
    controller.dataSource = context.coordinator
    controller.delegate = context.coordinator
    controller.view.accessibilityIdentifier = "pdfReader"
    controller.view.backgroundColor = .systemBackground
    if let page = context.coordinator.page(at: pageIndex) {
      controller.setViewControllers([page], direction: .forward, animated: false)
    }
    return controller
  }

  func updateUIViewController(_ controller: UIPageViewController, context: Context) {
    context.coordinator.onTurn = onTurn
    context.coordinator.show(pageIndex, in: controller)
  }

  @MainActor
  final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    let document: PDFDocument
    private var currentIndex: Int
    private var pages: [Int: PDFPageController] = [:]
    var onTurn: (Int) -> Void

    init(document: PDFDocument, pageIndex: Int, onTurn: @escaping (Int) -> Void) {
      self.document = document
      currentIndex = pageIndex
      self.onTurn = onTurn
    }

    fileprivate func page(at index: Int) -> PDFPageController? {
      guard (0..<document.pageCount).contains(index) else { return nil }
      if let cached = pages[index] { return cached }
      let page = PDFPageController(document: document, index: index)
      if abs(index - currentIndex) <= 1 { pages[index] = page }
      return page
    }

    func show(_ index: Int, in controller: UIPageViewController) {
      guard index != currentIndex, (0..<document.pageCount).contains(index) else { return }
      let direction: UIPageViewController.NavigationDirection =
        index > currentIndex ? .forward : .reverse
      currentIndex = index
      pages = pages.filter { abs($0.key - currentIndex) <= 1 }
      if let page = page(at: index) {
        controller.setViewControllers([page], direction: direction, animated: false)
      }
    }

    func pageViewController(
      _ controller: UIPageViewController, viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
      guard let page = viewController as? PDFPageController else { return nil }
      return self.page(at: page.index - 1)
    }

    func pageViewController(
      _ controller: UIPageViewController, viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
      guard let page = viewController as? PDFPageController else { return nil }
      return self.page(at: page.index + 1)
    }

    func pageViewController(
      _ controller: UIPageViewController, didFinishAnimating finished: Bool,
      previousViewControllers: [UIViewController], transitionCompleted completed: Bool
    ) {
      guard completed, let page = controller.viewControllers?.first as? PDFPageController
      else {
        return
      }
      currentIndex = page.index
      pages = pages.filter { abs($0.key - currentIndex) <= 1 }
      pages[currentIndex] = page
      onTurn(currentIndex)
    }

    func pageViewController(
      _ controller: UIPageViewController, spineLocationFor orientation: UIInterfaceOrientation
    ) -> UIPageViewController.SpineLocation { .min }
  }
}

private final class PDFPageController: UIViewController {
  let index: Int
  private let document: PDFDocument

  init(document: PDFDocument, index: Int) {
    self.document = document
    self.index = index
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func loadView() {
    let pdf = PDFView()
    pdf.displayMode = .singlePage
    pdf.displaysPageBreaks = false
    pdf.autoScales = true
    pdf.backgroundColor = .systemBackground
    pdf.document = document
    if let page = document.page(at: index) { pdf.go(to: page) }
    view = pdf
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard let pdf = view as? PDFView else { return }
    pdf.scaleFactor = pdf.scaleFactorForSizeToFit
  }
}
