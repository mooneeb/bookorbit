import CoreGraphics
import Vision
import XCTest

extension XCTestCase {
  @MainActor
  func assertPDFSearchHighlight(
    in app: XCUIApplication, page: Int, present: Bool, state: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let image = try XCTUnwrap(
      app.otherElements["pdfReader"].screenshot().image.cgImage, file: file, line: line)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let text = try XCTUnwrap(
      request.results?.compactMap { $0.topCandidates(1).first }.first {
        $0.string == "Orbit fixture: passage \(page)"
      }, "The actual PDF pixels must contain the literal delivered passage", file: file, line: line)
    var fractions: [String: Double] = [:]
    var bounds: [String: [Double]] = [:]
    for phrase in ["Orbit fixture:", "passage \(page)"] {
      let range = try XCTUnwrap(text.string.range(of: phrase), file: file, line: line)
      let box = try XCTUnwrap(try text.boundingBox(for: range), file: file, line: line).boundingBox
      let rectangle = CGRect(
        x: box.minX * Double(image.width), y: (1 - box.maxY) * Double(image.height),
        width: box.width * Double(image.width), height: box.height * Double(image.height)
      ).integral
      let crop = try XCTUnwrap(image.cropping(to: rectangle), file: file, line: line)
      var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
      let bluePixels = try pixels.withUnsafeMutableBytes { buffer in
        let context = try XCTUnwrap(
          CGContext(
            data: buffer.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
              | CGImageAlphaInfo.premultipliedLast.rawValue), file: file, line: line)
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return stride(from: 0, to: buffer.count, by: 4).filter { offset in
          let red = Int(buffer[offset])
          let green = Int(buffer[offset + 1])
          let blue = Int(buffer[offset + 2])
          return blue > 150 && blue - red > 20 && blue - green > 8
        }.count
      }
      fractions[phrase] = Double(bluePixels) / Double(crop.width * crop.height)
      bounds[phrase] = [Double(box.minX), Double(box.minY), Double(box.width), Double(box.height)]
    }
    let attachment = XCTAttachment(
      data: try JSONSerialization.data(withJSONObject: [
        "recognizedText": text.string, "highlightExpected": present,
        "blueFractions": fractions, "recognizedBounds": bounds,
      ]), uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E01-A04-pdf-search-pixels-\(state)"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(fractions["Orbit fixture:"], file: file, line: line), 0.01,
      "The unselected prefix must retain the PDF's plain background", file: file, line: line)
    let match = try XCTUnwrap(fractions["passage \(page)"], file: file, line: line)
    if present {
      XCTAssertGreaterThan(
        match, 0.3, "The selected match must have a visible blue highlight", file: file, line: line)
    } else {
      XCTAssertLessThanOrEqual(
        match, 0.01, "A new session or page turn must not retain the search highlight",
        file: file, line: line)
    }
  }
}
