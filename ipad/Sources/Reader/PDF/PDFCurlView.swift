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
  var inkEditor: PDFSourceInkEditor?
  var passageRepair: PDFPassageRepairModel?
  var passages: PDFPassageAnnotationModel?

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
        (controller as? PDFPageController)?.update(
          settings: settings, selection: selection, inkEditor: inkEditor,
          passageRepair: passageRepair, passages: passages)
      },
      onTurn: onTurn, onLayout: onLayout, onTransition: onTransition,
      onVisible: { pages in Task { await inkEditor?.preparePages(pages) } },
      allowsNavigation: inkEditor?.isDrawingStroke != true && passageRepair?.locksPage != true,
      allowsPencilNavigation: inkEditor?.mode.isWriting != true
    )
  }
}

private final class PDFPageController: UIViewController {
  let index: Int
  private let document: PDFDocument
  private let pdf = PDFView()
  private var settings = PdfReaderSettings.readerDefault
  private var inkEditor: PDFSourceInkEditor?
  private let inkCanvas = PDFSourceInkCanvas()
  private var passageRepair: PDFPassageRepairModel?
  private var repairFixtureGeneration = 0
  private var passages: PDFPassageAnnotationModel?
  private let privatePassages = PDFPassageAnnotationOverlay()
  private var passageFixtureGeneration = 0

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
    view.addSubview(inkCanvas)
    view.addSubview(privatePassages)
    NotificationCenter.default.addObserver(
      self, selector: #selector(selectionChanged),
      name: .PDFViewSelectionChanged, object: pdf)
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
    pdf.layoutDocumentView()
    pdf.layoutIfNeeded()
    layoutInk()
    layoutPrivatePassages()
  }

  private func layoutInk() {
    guard let editor = inkEditor, let page = document.page(at: index) else {
      inkCanvas.isHidden = true
      return
    }
    inkCanvas.isHidden = false
    let crop = page.bounds(for: .cropBox)
    let rotation = ((page.rotation % 360) + 360) % 360
    let size =
      rotation % 180 == 0
      ? crop.size
      : CGSize(width: crop.height, height: crop.width)
    func pdfPoint(_ point: CGPoint) -> CGPoint {
      switch rotation {
      case 90: return CGPoint(x: crop.minX + point.y, y: crop.minY + point.x)
      case 180: return CGPoint(x: crop.maxX - point.x, y: crop.minY + point.y)
      case 270: return CGPoint(x: crop.maxX - point.y, y: crop.maxY - point.x)
      default: return CGPoint(x: crop.minX + point.x, y: crop.maxY - point.y)
      }
    }
    func screenPoint(_ point: CGPoint) -> CGPoint {
      view.convert(pdf.convert(pdfPoint(point), from: page), from: pdf)
    }
    let origin = screenPoint(.zero)
    let x = screenPoint(CGPoint(x: 1, y: 0))
    let y = screenPoint(CGPoint(x: 0, y: 1))
    inkCanvas.layer.anchorPoint = .zero
    inkCanvas.bounds = CGRect(origin: .zero, size: size)
    inkCanvas.layer.position = origin
    inkCanvas.transform = CGAffineTransform(
      a: x.x - origin.x, b: x.y - origin.y,
      c: y.x - origin.x, d: y.y - origin.y, tx: 0, ty: 0)
    inkCanvas.update(editor: editor, pageIndex: index, size: size)
    let represented = inkCanvas.visibleAnnotationIDs.union(
      editor.items.filter {
        $0.pdf?.page == index && $0.deletedAt != nil
      }.map(\.id))
    for annotation in page.annotations {
      if let identifier = annotation.value(
        forAnnotationKey:
          PDFAnnotationKey(rawValue: "/BookOrbitAnnotationId")) as? NSNumber,
        represented.contains(identifier.intValue),
        annotation.value(forAnnotationKey: .name) as? String == "bookorbit:\(identifier.intValue)"
      {
        page.removeAnnotation(annotation)
      }
    }
  }

  private func layoutPrivatePassages() {
    privatePassages.frame = view.bounds
    guard let passages, let page = document.page(at: index) else { return }
    let crop = page.bounds(for: .cropBox)
    let rotation = ((page.rotation % 360) + 360) % 360
    func point(_ value: CGPoint) -> CGPoint {
      switch rotation {
      case 90: return CGPoint(x: crop.minX + value.y, y: crop.minY + value.x)
      case 180: return CGPoint(x: crop.maxX - value.x, y: crop.minY + value.y)
      case 270: return CGPoint(x: crop.maxX - value.y, y: crop.maxY - value.x)
      default: return CGPoint(x: crop.minX + value.x, y: crop.maxY - value.y)
      }
    }
    privatePassages.update(
      items: passages.items(on: index),
      frameForRect: { rect in
        let corners = [
          CGPoint(x: rect.x, y: rect.y),
          CGPoint(x: rect.x + rect.width, y: rect.y + rect.height),
        ].map {
          self.view.convert(self.pdf.convert(point($0), from: page), from: self.pdf)
        }
        return CGRect(
          x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
          width: abs(corners[1].x - corners[0].x), height: abs(corners[1].y - corners[0].y))
      }, open: passages.open)
  }

  @objc private func selectionChanged() {
    passageRepair?.selected(pdf.currentSelection)
    passages?.selected(pdf.currentSelection)
  }

  func update(
    settings: PdfReaderSettings, selection: PDFSelection?, inkEditor: PDFSourceInkEditor?,
    passageRepair: PDFPassageRepairModel?, passages: PDFPassageAnnotationModel?
  ) {
    loadViewIfNeeded()
    self.settings = settings
    self.inkEditor = inkEditor
    self.passageRepair = passageRepair
    self.passages = passages
    if let passageRepair {
      inkEditor?.mode.isWriting = false
      if passageRepair.fixtureGeneration != repairFixtureGeneration,
        index == inkEditor?.currentPage, let page = document.page(at: index),
        let text = page.string
      {
        repairFixtureGeneration = passageRepair.fixtureGeneration
        let source = text as NSString
        let phrase = source.range(of: "Orbit fixture: passage \(index + 1)")
        let range =
          phrase.location == NSNotFound
          ? NSRange(location: 0, length: min(128, source.length)) : phrase
        pdf.currentSelection = page.selection(for: range)
        selectionChanged()
      }
    }
    if let passages, passages.selectionFixtureGeneration != passageFixtureGeneration,
      index == inkEditor?.currentPage, let page = document.page(at: index), let text = page.string
    {
      passageFixtureGeneration = passages.selectionFixtureGeneration
      let text = text as NSString
      let phrase = text.range(of: "Orbit fixture: passage \(index + 1)")
      let range =
        phrase.location == NSNotFound
        ? NSRange(location: 0, length: min(128, text.length)) : phrase
      pdf.currentSelection = page.selection(for: range)
      selectionChanged()
    }
    selection?.color = pdf.tintColor.withAlphaComponent(0.25)
    let privatePreview = passages?.presentation.flatMap {
      $0.item == nil ? $0.preview.selection : nil
    }
    pdf.highlightedSelections = (passageRepair?.preview?.selection ?? privatePreview ?? selection)
      .map { [$0] }
    layoutPage()
  }
}
