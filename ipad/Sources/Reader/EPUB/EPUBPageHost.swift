import SwiftUI
import UIKit

struct EPUBPageHost: UIViewControllerRepresentable {
  let model: EPUBReaderModel
  let pencilMode: PencilReaderMode

  func makeUIViewController(context: Context) -> EPUBPageController {
    EPUBPageController(model: model, pencilMode: pencilMode)
  }

  func updateUIViewController(_ controller: EPUBPageController, context: Context) {}

  static func dismantleUIViewController(_ controller: EPUBPageController, coordinator: Void) {
    controller.detach()
  }
}

@MainActor
final class EPUBPageController: UIViewController, UIGestureRecognizerDelegate {
  private let model: EPUBReaderModel
  private let pencilMode: PencilReaderMode
  private var pager: UIPageViewController?
  private var page = EPUBContentController()
  private var mode = ReaderTurnAnimation.curl
  private var completion: CheckedContinuation<Void, Never>?
  private var transitionID: UUID?
  private var pan: UIPanGestureRecognizer?
  private var isDetached = false
  private var completionTimeout: Task<Void, Never>?
  private var lastSize = CGSize.zero
  private var layoutTask: Task<Void, Never>?
  private var isRotating = false

  init(model: EPUBReaderModel, pencilMode: PencilReaderMode) {
    self.model = model
    self.pencilMode = pencilMode
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    view = UIView()
    view.backgroundColor = .systemBackground
    view.accessibilityIdentifier = "epubNativePages"
    view.addInteraction(UIPencilInteraction(delegate: pencilMode))
    installPager(mode)
    page.attach(model.webView)
    let gesture = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))
    gesture.delegate = self
    gesture.maximumNumberOfTouches = 1
    gesture.allowedTouchTypes = [
      NSNumber(value: UITouch.TouchType.direct.rawValue),
      NSNumber(value: UITouch.TouchType.pencil.rawValue),
    ]
    gesture.cancelsTouchesInView = false
    view.addGestureRecognizer(gesture)
    pan = gesture
    model.prepareTurn = { [weak self] image in self?.page.show(image) }
    model.commitTurn = { [weak self] forward, animation in
      await self?.transition(forward: forward, animation: animation)
    }
    model.cancelTurn = { [weak self] in self?.cancelTransition() }
  }

  func detach() {
    guard !isDetached else { return }
    isDetached = true
    cancelTransition()
    layoutTask?.cancel()
    model.prepareTurn = nil
    model.commitTurn = nil
    model.cancelTurn = nil
    model.webView.removeFromSuperview()
  }

  override func viewWillTransition(
    to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator
  ) {
    let cfi = model.visibleLocation?.cfi
    let continuous = model.isContinuous
    let anchor = Task { continuous ? await model.layoutAnchor() : cfi }
    isRotating = true
    super.viewWillTransition(to: size, with: coordinator)
    coordinator.animate(alongsideTransition: nil) { [weak self] _ in
      guard let self else { return }
      self.isRotating = false
      self.lastSize = self.view.bounds.size
      Task {
        if let cfi = await anchor.value { await self.model.preserveLayout(at: cfi) }
      }
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let size = view.bounds.size
    guard size != lastSize, size.width > 0, size.height > 0 else { return }
    let hadSize = lastSize != .zero
    lastSize = size
    guard hadSize, !isRotating else { return }
    let cfi = model.visibleLocation?.cfi
    let continuous = model.isContinuous
    layoutTask?.cancel()
    layoutTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      guard let self, !self.isDetached else { return }
      let target = continuous ? await self.model.layoutAnchor() : cfi
      if let target { await self.model.preserveLayout(at: target) }
    }
  }

  private func installPager(_ animation: ReaderTurnAnimation) {
    if let pager {
      pager.willMove(toParent: nil)
      pager.view.removeFromSuperview()
      pager.removeFromParent()
    }
    let next = UIPageViewController(
      transitionStyle: animation == .curl ? .pageCurl : .scroll,
      navigationOrientation: animation == .verticalSlide ? .vertical : .horizontal,
      options: animation == .curl
        ? [.spineLocation: UIPageViewController.SpineLocation.min.rawValue] : nil)
    next.isDoubleSided = false
    addChild(next)
    next.view.frame = view.bounds
    next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(next.view)
    next.didMove(toParent: self)
    next.setViewControllers([page], direction: .forward, animated: false)
    pager = next
    mode = animation
  }

  private func transition(forward: Bool, animation: ReaderTurnAnimation) async {
    guard !isDetached else { return }
    cancelPendingCompletion()
    if animation == .none {
      page.clearSnapshot()
      return
    }
    let id = UUID()
    transitionID = id
    await withCheckedContinuation { continuation in
      completion = continuation
      completionTimeout = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        guard let self, self.transitionID == id else { return }
        self.cancelTransition()
      }
      if animation == .fade {
        UIView.transition(
          with: page.view, duration: 0.2,
          options: [.transitionCrossDissolve, .allowAnimatedContent],
          animations: { self.page.clearSnapshot() },
          completion: { [weak self] _ in self?.finish(id) })
        return
      }
      if mode != animation { installPager(animation) }
      let next = EPUBContentController()
      next.view.frame = page.view.bounds
      next.attach(model.webView)
      let old = page
      page = next
      let direction: UIPageViewController.NavigationDirection =
        (animation == .verticalSlide ? forward : forward != model.rightToLeft) ? .forward : .reverse
      pager?.setViewControllers([next], direction: direction, animated: true) { [weak self] _ in
        old.clearSnapshot()
        self?.finish(id)
      }
    }
  }

  private func finish(_ id: UUID) {
    guard transitionID == id else { return }
    completionTimeout?.cancel()
    completionTimeout = nil
    transitionID = nil
    let saved = completion
    completion = nil
    saved?.resume()
  }

  private func cancelPendingCompletion() {
    completionTimeout?.cancel()
    completionTimeout = nil
    transitionID = nil
    let saved = completion
    completion = nil
    saved?.resume()
  }

  private func cancelTransition() {
    cancelPendingCompletion()
    viewIfLoaded?.layer.removeAllAnimations()
    page.viewIfLoaded?.layer.removeAllAnimations()
    page.attach(model.webView)
    page.clearSnapshot()
    pager?.setViewControllers([page], direction: .forward, animated: false)
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === pan, model.canNavigate, !model.isPencilMarking,
      model.annotationWriting || model.selectionCFI == nil,
      !model.isContinuous, let pan
    else { return false }
    let velocity = pan.velocity(in: view)
    return model.preferences.value.pageAnimation == .verticalSlide
      ? abs(velocity.y) > abs(velocity.x) * 1.2
      : abs(velocity.x) > abs(velocity.y) * 1.2
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  {
    gestureRecognizer !== pan || touch.type != .pencil || !model.annotationWriting
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    gestureRecognizer === pan || otherGestureRecognizer === pan
  }

  @objc private func didPan(_ gesture: UIPanGestureRecognizer) {
    guard gesture.state == .ended, model.canNavigate, !model.isPencilMarking,
      model.annotationWriting || model.selectionCFI == nil
    else { return }
    let movement = gesture.translation(in: view)
    let vertical = model.preferences.value.pageAnimation == .verticalSlide
    let distance = vertical ? movement.y : movement.x
    guard abs(distance) >= 60 else { return }
    let forward = vertical ? distance < 0 : (distance < 0) != model.rightToLeft
    Task { await model.turn(forward: forward) }
  }
}

@MainActor
private final class EPUBContentController: UIViewController {
  private var snapshot: UIImageView?

  override func loadView() {
    view = UIView()
    view.backgroundColor = .systemBackground
  }

  func attach(_ content: UIView) {
    loadViewIfNeeded()
    content.removeFromSuperview()
    content.frame = view.bounds
    content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.insertSubview(content, at: 0)
  }

  func show(_ image: UIImage) {
    loadViewIfNeeded()
    clearSnapshot()
    let snapshot = UIImageView(image: image)
    snapshot.frame = view.bounds
    snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    snapshot.contentMode = .scaleToFill
    snapshot.isAccessibilityElement = false
    snapshot.accessibilityElementsHidden = true
    view.addSubview(snapshot)
    self.snapshot = snapshot
  }

  func clearSnapshot() {
    snapshot?.removeFromSuperview()
    snapshot = nil
  }
}
