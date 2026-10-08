import SwiftUI
import UIKit

struct FixedReaderSurface: View {
  let pageCount: Int
  let pageIndex: Int
  let animation: ReaderTurnAnimation
  let identifier: String
  let facingMode: String
  let singlePrefix: Int
  let forceFacing: Bool
  let minimumFacingAspect: CGFloat
  let continuousAxis: String?
  let rightToLeft: Bool
  let spreadGap: CGFloat
  let pageGap: CGFloat
  let pageHeight: (Int, CGSize) -> CGFloat
  let makePage: (Int) -> UIViewController
  let refreshPage: (UIViewController, Int) -> Void
  let onTurn: (Int) -> Void
  let onLayout: (FixedPageLayout) -> Void
  let onTransition: (Bool) -> Void
  var onVisible: (Set<Int>) -> Void = { _ in }
  var onBeyondLast: (() -> Void)?
  var facingLayout: FixedPageLayout?
  var usesVirtualBlanks = false
  var allowsNavigation = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      let facing =
        facingMode == "always"
        || facingMode == "auto"
          && (forceFacing
            || geometry.size.width >= 900
              && geometry.size.width / max(1, geometry.size.height) >= minimumFacingAspect)
      let ordinaryLayout = FixedPageLayout(
        pageCount: pageCount, facing: facing, singlePrefix: singlePrefix)
      let layout =
        facingLayout.flatMap {
          facing && $0.pageCount == pageCount && $0.singlePrefix == singlePrefix ? $0 : nil
        } ?? ordinaryLayout
      let effectiveAnimation = reduceMotion ? ReaderTurnAnimation.none : animation
      Group {
        if let continuousAxis {
          NativeContinuousPagesView(
            pageCount: layout.unitCount, pageIndex: layout.unit(for: pageIndex),
            horizontal: continuousAxis == "horizontal", gap: pageGap, identifier: identifier,
            height: { unit, width in
              let pages = layout.pages(in: unit)
              let pageWidth =
                (width - (pages.count == 2 ? spreadGap : 0)) / CGFloat(max(1, pages.count))
              return pages.map {
                pageHeight($0, CGSize(width: pageWidth, height: geometry.size.height))
              }.max() ?? geometry.size.height
            },
            makePage: { unit in makeUnit(layout: layout, unit: unit) },
            refreshPage: refreshUnit,
            onTurn: { unit in if let page = layout.pages(in: unit).first { onTurn(page) } },
            onVisible: { units in onVisible(Set(units.flatMap { layout.pages(in: $0) })) },
            allowsNavigation: allowsNavigation)
        } else {
          NativePagedView(
            pageCount: layout.unitCount, pageIndex: layout.unit(for: pageIndex),
            animation: effectiveAnimation, identifier: identifier,
            makePage: { unit in makeUnit(layout: layout, unit: unit) }, refreshPage: refreshUnit,
            onTurn: { unit in if let page = layout.pages(in: unit).first { onTurn(page) } },
            onTransition: onTransition, rightToLeft: rightToLeft, onBeyondLast: onBeyondLast,
            allowsNavigation: allowsNavigation)
        }
      }
      .id(
        SurfaceIdentity(
          facing: facing, prefix: singlePrefix, axis: continuousAxis, animation: effectiveAnimation,
          rtl: rightToLeft, layoutRevision: layout.revision)
      )
      .onChange(of: layout, initial: true) { _, value in onLayout(value) }
    }
  }

  private func makeUnit(layout: FixedPageLayout, unit: Int) -> UIViewController {
    FixedSpreadController(
      pages: layout.pages(in: unit), makePage: makePage, rightToLeft: rightToLeft, gap: spreadGap,
      virtualBlank: usesVirtualBlanks && layout.hasVirtualBlank(in: unit))
  }

  private func refreshUnit(_ controller: UIViewController, _ unit: Int) {
    guard let spread = controller as? FixedSpreadController else { return }
    spread.gap = spreadGap
    for (index, child) in spread.pages { refreshPage(child, index) }
    spread.view.setNeedsLayout()
  }
}

private struct SurfaceIdentity: Hashable {
  let facing: Bool
  let prefix: Int
  let axis: String?
  let animation: ReaderTurnAnimation
  let rtl: Bool
  let layoutRevision: Int
}

@MainActor private final class FixedSpreadController: UIViewController {
  let pages: [(Int, UIViewController)]
  let rightToLeft: Bool
  var gap: CGFloat
  private let virtualBlank: Bool

  init(
    pages: [Int], makePage: (Int) -> UIViewController, rightToLeft: Bool, gap: CGFloat,
    virtualBlank: Bool
  ) {
    self.pages = (rightToLeft ? Array(pages.reversed()) : pages).map { ($0, makePage($0)) }
    self.rightToLeft = rightToLeft
    self.virtualBlank = virtualBlank
    self.gap = gap
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func loadView() {
    view = UIView()
    view.backgroundColor = .systemBackground
    for (_, child) in pages {
      addChild(child)
      view.addSubview(child.view)
      child.didMove(toParent: self)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let slots = virtualBlank ? 2 : max(1, pages.count)
    let spacing = slots == 2 ? gap : 0
    let width = max(0, (view.bounds.width - spacing) / CGFloat(slots))
    for (offset, pair) in pages.enumerated() {
      let slot = virtualBlank && rightToLeft ? 1 : offset
      pair.1.view.frame = CGRect(
        x: CGFloat(slot) * (width + spacing), y: 0, width: width, height: view.bounds.height)
    }
  }
}
