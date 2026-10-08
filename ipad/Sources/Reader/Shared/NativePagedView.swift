import SwiftUI
import UIKit

struct NativePagedView: UIViewControllerRepresentable {
  let pageCount: Int
  let pageIndex: Int
  let animation: ReaderTurnAnimation
  let identifier: String
  let makePage: (Int) -> UIViewController
  let refreshPage: (UIViewController, Int) -> Void
  let onTurn: (Int) -> Void
  var onTransition: (Bool) -> Void = { _ in }
  var rightToLeft = false
  var onBeyondLast: (() -> Void)?
  var allowsNavigation = true

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIViewController(context: Context) -> UIViewController {
    let controller: UIViewController
    if animation == .fade || animation == .none {
      let discrete = DiscretePageController(fades: animation == .fade)
      discrete.rightToLeft = rightToLeft
      discrete.onNavigate = context.coordinator.navigate
      controller = discrete
    } else {
      let pages = UIPageViewController(
        transitionStyle: animation == .curl ? .pageCurl : .scroll,
        navigationOrientation: animation == .verticalSlide ? .vertical : .horizontal,
        options: animation == .curl
          ? [.spineLocation: (rightToLeft ? UIPageViewController.SpineLocation.max : .min).rawValue]
          : nil)
      pages.isDoubleSided = false
      pages.dataSource = context.coordinator
      pages.delegate = context.coordinator
      controller = pages
    }
    controller.view.accessibilityIdentifier = identifier
    controller.view.backgroundColor = .systemBackground
    context.coordinator.install(in: controller)
    applyNavigation(to: controller)
    return controller
  }

  func updateUIViewController(_ controller: UIViewController, context: Context) {
    context.coordinator.configuration = self
    applyNavigation(to: controller)
    (controller as? DiscretePageController)?.rightToLeft = rightToLeft
    context.coordinator.show(pageIndex, in: controller)
    context.coordinator.refresh()
  }

  private func applyNavigation(to controller: UIViewController) {
    if let pager = controller as? UIPageViewController {
      for gesture in pager.gestureRecognizers { gesture.isEnabled = allowsNavigation }
      for subview in pager.view.subviews {
        (subview as? UIScrollView)?.isScrollEnabled = allowsNavigation
      }
    } else {
      for gesture in controller.view.gestureRecognizers ?? [] {
        gesture.isEnabled = allowsNavigation
      }
    }
  }

  @MainActor
  final class Coordinator: NSObject,
    UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate
  {
    var configuration: NativePagedView
    private var currentIndex: Int
    private var requestedIndex: Int
    private var pages: [Int: UIViewController] = [:]
    private var isTransitioning = false
    private var boundaryPan: UIPanGestureRecognizer?
    private var boundaryEligible = false

    init(_ configuration: NativePagedView) {
      self.configuration = configuration
      currentIndex = configuration.pageIndex
      requestedIndex = currentIndex
    }

    private func page(at index: Int) -> UIViewController? {
      guard (0..<configuration.pageCount).contains(index), abs(index - currentIndex) <= 1
      else { return nil }
      if let page = pages[index] { return page }
      let page = configuration.makePage(index)
      configuration.refreshPage(page, index)
      pages[index] = page
      return page
    }

    func install(in controller: UIViewController) {
      guard let page = page(at: currentIndex) else { return }
      if let pager = controller as? UIPageViewController {
        pager.setViewControllers([page], direction: .forward, animated: false)
        if configuration.onBeyondLast != nil {
          let gesture = UIPanGestureRecognizer(target: self, action: #selector(attemptBoundary(_:)))
          gesture.delegate = self
          gesture.cancelsTouchesInView = false
          gesture.maximumNumberOfTouches = 1
          controller.view.addGestureRecognizer(gesture)
          boundaryPan = gesture
        }
      } else if let discrete = controller as? DiscretePageController {
        discrete.show(page)
      }
    }

    func show(_ index: Int, in controller: UIViewController) {
      guard (0..<configuration.pageCount).contains(index) else { return }
      requestedIndex = index
      guard index != currentIndex, !isTransitioning else { return }
      let direction: UIPageViewController.NavigationDirection =
        (index > currentIndex) != configuration.rightToLeft ? .forward : .reverse
      currentIndex = index
      pages = pages.filter { abs($0.key - index) <= 1 }
      guard let page = page(at: index) else { return }
      if let pager = controller as? UIPageViewController {
        pager.setViewControllers([page], direction: direction, animated: false)
      } else if let discrete = controller as? DiscretePageController {
        discrete.show(page)
      }
    }

    func refresh() {
      for (index, page) in pages { configuration.refreshPage(page, index) }
    }

    func navigate(_ delta: Int) {
      guard configuration.allowsNavigation else { return }
      let next = currentIndex + delta
      guard !isTransitioning else { return }
      if next == configuration.pageCount, delta == 1 {
        configuration.onBeyondLast?()
        return
      }
      guard (0..<configuration.pageCount).contains(next) else { return }
      configuration.onTurn(next)
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      gestureRecognizer === boundaryPan || otherGestureRecognizer === boundaryPan
    }

    @objc private func attemptBoundary(_ gesture: UIPanGestureRecognizer) {
      if gesture.state == .began {
        boundaryEligible =
          !isTransitioning && currentIndex == configuration.pageCount - 1
          && !hasMovableContent(pages[currentIndex]?.view)
        return
      }
      guard gesture.state == .ended else {
        if gesture.state == .cancelled || gesture.state == .failed { boundaryEligible = false }
        return
      }
      defer { boundaryEligible = false }
      guard boundaryEligible, !isTransitioning,
        currentIndex == configuration.pageCount - 1,
        let view = gesture.view
      else { return }
      let translation = gesture.translation(in: view)
      let vertical = configuration.animation == .verticalSlide
      let movement = vertical ? translation.y : translation.x
      let crossAxis = vertical ? translation.x : translation.y
      guard abs(movement) >= 80, abs(movement) > abs(crossAxis) * 1.2,
        configuration.rightToLeft ? movement > 0 : movement < 0
      else { return }
      configuration.onBeyondLast?()
    }

    private func hasMovableContent(_ view: UIView?) -> Bool {
      guard let view else { return false }
      if let scroll = view as? UIScrollView {
        let extent =
          configuration.animation == .verticalSlide
          ? scroll.contentSize.height - scroll.bounds.height
          : scroll.contentSize.width - scroll.bounds.width
        if scroll.zoomScale > scroll.minimumZoomScale + 0.01 || extent > 1 { return true }
      }
      return view.subviews.contains { hasMovableContent($0) }
    }

    func pageViewController(
      _ controller: UIPageViewController, viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
      guard configuration.allowsNavigation else { return nil }
      guard let index = pages.first(where: { $0.value === viewController })?.key else { return nil }
      return page(at: index + (configuration.rightToLeft ? 1 : -1))
    }

    func pageViewController(
      _ controller: UIPageViewController, viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
      guard configuration.allowsNavigation else { return nil }
      guard let index = pages.first(where: { $0.value === viewController })?.key else { return nil }
      return page(at: index + (configuration.rightToLeft ? -1 : 1))
    }

    func pageViewController(
      _ controller: UIPageViewController,
      willTransitionTo pendingViewControllers: [UIViewController]
    ) {
      isTransitioning = true
      configuration.onTransition(true)
    }

    func pageViewController(
      _ controller: UIPageViewController, didFinishAnimating finished: Bool,
      previousViewControllers: [UIViewController], transitionCompleted completed: Bool
    ) {
      isTransitioning = false
      configuration.onTransition(false)
      guard completed, let visible = controller.viewControllers?.first,
        let index = pages.first(where: { $0.value === visible })?.key
      else {
        show(requestedIndex, in: controller)
        return
      }
      currentIndex = index
      pages = pages.filter { abs($0.key - index) <= 1 }
      configuration.onTurn(index)
    }

    func pageViewController(
      _ controller: UIPageViewController, spineLocationFor orientation: UIInterfaceOrientation
    ) -> UIPageViewController.SpineLocation { configuration.rightToLeft ? .max : .min }
  }
}

@MainActor private final class DiscretePageController: UIViewController {
  var onNavigate: (Int) -> Void = { _ in }
  var rightToLeft = false
  private let fades: Bool
  private var page: UIViewController?
  private var transitionGeneration = 0

  init(fades: Bool) {
    self.fades = fades
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { return nil }

  override func loadView() {
    view = UIView()
    for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
      let gesture = UISwipeGestureRecognizer(target: self, action: #selector(didSwipe))
      gesture.direction = direction
      view.addGestureRecognizer(gesture)
    }
    view.accessibilityCustomActions = [
      UIAccessibilityCustomAction(
        name: "Previous page", target: self, selector: #selector(accessibilityPreviousPage)),
      UIAccessibilityCustomAction(
        name: "Next page", target: self, selector: #selector(accessibilityNextPage)),
    ]
  }

  func show(_ next: UIViewController) {
    guard page !== next else { return }
    loadViewIfNeeded()
    transitionGeneration &+= 1
    let generation = transitionGeneration
    let old = page
    for child in children where child !== old {
      child.willMove(toParent: nil)
      child.view.layer.removeAllAnimations()
      child.view.removeFromSuperview()
      child.removeFromParent()
    }
    old?.view.layer.removeAllAnimations()
    old?.view.alpha = 1
    old?.willMove(toParent: nil)
    addChild(next)
    next.view.frame = view.bounds
    next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(next.view)
    next.didMove(toParent: self)
    page = next
    if fades, old != nil {
      next.view.alpha = 0
      UIView.animate(
        withDuration: 0.2, animations: { next.view.alpha = 1 },
        completion: { [weak self] _ in
          guard self?.transitionGeneration == generation else { return }
          old?.view.removeFromSuperview()
          old?.removeFromParent()
        })
    } else {
      old?.view.removeFromSuperview()
      old?.removeFromParent()
    }
  }

  @objc private func didSwipe(_ gesture: UISwipeGestureRecognizer) {
    onNavigate((gesture.direction == .left ? 1 : -1) * (rightToLeft ? -1 : 1))
  }
  @objc private func accessibilityPreviousPage() -> Bool {
    onNavigate(-1)
    return true
  }
  @objc private func accessibilityNextPage() -> Bool {
    onNavigate(1)
    return true
  }
}
