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
  var onLayout: (FixedPageLayout) -> Void = { _ in }
  var onTransition: (Bool) -> Void = { _ in }

  var body: some View {
    FixedReaderSurface(
      pageCount: document.pageCount, pageIndex: pageIndex, animation: animation,
      identifier: "pdfReader",
      facingMode: settings.spread == "auto"
        ? "auto" : settings.spread == "none" ? "never" : "always",
      singlePrefix: settings.spread == "even" ? 1 : 0, forceFacing: false, minimumFacingAspect: 1.1,
      continuousAxis: settings.scrollMode == "page" ? nil : settings.scrollMode,
      rightToLeft: false, spreadGap: 12, pageGap: 12,
      pageHeight: { index, size in
        if settings.zoomMode == "fit-page" || settings.zoomMode == "automatic" {
          return size.height
        }
        guard let page = document.page(at: index) else { return size.height }
        let bounds = page.bounds(for: .cropBox)
        let rotated = (page.rotation + settings.rotation) % 180 != 0
        let pageWidth = rotated ? bounds.height : bounds.width
        let pageHeight = rotated ? bounds.width : bounds.height
        if settings.zoomMode == "custom" { return pageHeight * settings.customScale }
        return pageWidth > 0 ? size.width * pageHeight / pageWidth : size.height
      },
      makePage: { PDFPageController(document: document, index: $0) },
      refreshPage: { controller, _ in
        (controller as? PDFPageController)?.update(settings: settings, selection: selection)
      },
      onTurn: onTurn, onLayout: onLayout, onTransition: onTransition
    )
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
