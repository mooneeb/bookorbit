import PDFKit
import SwiftUI
import UIKit

struct PDFCurlView: View {
  let document: PDFDocument
  let pageIndex: Int
  let selection: PDFSelection?
  let onTurn: (Int) -> Void
  var settings = PdfReaderSettings.readerDefault
  var animation = ReaderTurnAnimation.curl
  var onTransition: (Bool) -> Void = { _ in }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let effectiveAnimation = reduceMotion ? ReaderTurnAnimation.none : animation
    NativePagedView(
      pageCount: document.pageCount, pageIndex: pageIndex, animation: effectiveAnimation,
      identifier: "pdfReader",
      makePage: { PDFPageController(document: document, index: $0) },
      refreshPage: { controller, _ in
        (controller as? PDFPageController)?.update(settings: settings, selection: selection)
      },
      onTurn: onTurn, onTransition: onTransition
    )
    .id(effectiveAnimation)
  }
}

private final class PDFPageController: UIViewController {
  let index: Int
  private let document: PDFDocument
  private let pdf = PDFView()
  private var settings = PdfReaderSettings.readerDefault

  init(document: PDFDocument, index: Int) {
    self.document = document
    self.index = index
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func loadView() {
    view = UIView()
    view.backgroundColor = .systemBackground
    pdf.displayMode = .singlePage
    pdf.displaysPageBreaks = false
    pdf.backgroundColor = .systemBackground
    pdf.document = document
    if let page = document.page(at: index) { pdf.go(to: page) }
    view.addSubview(pdf)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layoutPage()
  }

  private func layoutPage() {
    let swapsDimensions = settings.rotation % 180 != 0
    pdf.bounds = CGRect(
      origin: .zero,
      size: swapsDimensions
        ? CGSize(width: view.bounds.height, height: view.bounds.width) : view.bounds.size)
    pdf.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    pdf.transform = CGAffineTransform(rotationAngle: CGFloat(settings.rotation) * .pi / 180)
    pdf.autoScales = settings.zoomMode == "automatic"
    if settings.zoomMode == "custom" {
      pdf.scaleFactor = settings.customScale
    } else if settings.zoomMode == "fit-width", let page = document.page(at: index) {
      let width = page.bounds(for: pdf.displayBox).width
      if width > 0 { pdf.scaleFactor = pdf.bounds.width / width }
    } else {
      pdf.scaleFactor = pdf.scaleFactorForSizeToFit
    }
  }

  func update(settings: PdfReaderSettings, selection: PDFSelection?) {
    loadViewIfNeeded()
    self.settings = settings
    selection?.color = pdf.tintColor.withAlphaComponent(0.25)
    pdf.highlightedSelections = selection.map { [$0] }
    layoutPage()
  }
}
