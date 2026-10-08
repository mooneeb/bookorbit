import CoreGraphics
import Foundation
import PDFKit

// This single-page copy belongs only to its worker; the live reader document stays on the main actor.
struct PDFThumbnailPage: @unchecked Sendable {
  let page: CGPDFPage
  let snapshot: PDFPage
  let bounds: CGRect
  let pageTransform: CGAffineTransform
  let rotation: Int
}

struct PDFThumbnailBitmap: @unchecked Sendable {
  let image: CGImage
  var byteCount: Int { image.bytesPerRow * image.height }
}

enum PDFThumbnailRasterizer {
  nonisolated static func render(_ source: PDFThumbnailPage) -> PDFThumbnailBitmap? {
    guard !Task.isCancelled else { return nil }
    return autoreleasepool {
      let bounds = source.bounds
      guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0
      else { return nil }
      let rotated = (Int(source.page.rotationAngle) + source.rotation) % 180 != 0
      let width = rotated ? bounds.height : bounds.width
      let height = rotated ? bounds.width : bounds.height
      let longestEdge = max(width, height)
      let pixelWidth = max(1, min(320, Int((width / longestEdge * 320).rounded())))
      let pixelHeight = max(1, min(320, Int((height / longestEdge * 320).rounded())))
      guard !Task.isCancelled,
        let context = CGContext(
          data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
          bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      let target = CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
      context.setFillColor(gray: 1, alpha: 1)
      context.fill(target)
      context.concatenate(
        source.page.getDrawingTransform(
          .cropBox, rect: target, rotate: Int32(source.rotation), preserveAspectRatio: true))
      // PDFKit applies the crop and rotation transform again when drawing page annotations.
      context.concatenate(source.pageTransform.inverted())
      guard !Task.isCancelled else { return nil }
      source.snapshot.draw(with: .cropBox, to: context)
      guard !Task.isCancelled, let image = context.makeImage() else { return nil }
      return PDFThumbnailBitmap(image: image)
    }
  }
}
