import Foundation
import PencilKit
import UIKit

enum PDFSourceInkDrawing {
  static let maximumPoints = 24_000
  static let maximumStrokePoints = 10_000
  static let maximumStrokes = 1_000
  static let maximumNativeDataCharacters = 2_000_000
  static let maximumNativeDataBytes = maximumNativeDataCharacters / 4 * 3

  static func decode(_ drawing: NativeAnnotationDrawing) -> PKDrawing? {
    if let encoded = drawing.nativeData, let data = Data(base64Encoded: encoded),
      data.count <= 4 * 1024 * 1024, let retained = try? PKDrawing(data: data)
    {
      return retained
    }
    guard drawing.strokes.reduce(0, { $0 + $1.points.count }) <= maximumPoints else {
      return nil
    }
    let strokes = drawing.strokes.compactMap { stroke -> PKStroke? in
      guard !stroke.points.isEmpty, stroke.width.isFinite, stroke.width > 0 else { return nil }
      let points = stroke.points.enumerated().compactMap { index, point -> PKStrokePoint? in
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return PKStrokePoint(
          location: CGPoint(x: point.x, y: point.y), timeOffset: Double(index) * 0.01,
          size: CGSize(width: stroke.width, height: stroke.width), opacity: 1,
          force: CGFloat(point.pressure ?? 1), azimuth: 0, altitude: .pi / 2)
      }
      guard points.count == stroke.points.count else { return nil }
      return PKStroke(
        ink: PKInk(.pen, color: color(stroke.color)),
        path: PKStrokePath(controlPoints: points, creationDate: .distantPast))
    }
    guard strokes.count == drawing.strokes.count else { return nil }
    return PKDrawing(strokes: strokes)
  }

  static func encode(_ drawing: PKDrawing, preserving previous: NativeAnnotationDrawing? = nil)
    throws -> NativeAnnotationDrawing?
  {
    guard !drawing.strokes.isEmpty else { return nil }
    guard drawing.strokes.count <= maximumStrokes else {
      throw PDFSourceInkEncodingError.tooManyStrokes
    }
    let data = drawing.dataRepresentation()
    guard data.count <= maximumNativeDataBytes else {
      throw PDFSourceInkEncodingError.tooLarge
    }
    let encoded = data.base64EncodedString()
    guard encoded.utf8.count <= maximumNativeDataCharacters else {
      throw PDFSourceInkEncodingError.tooLarge
    }
    var count = 0
    var strokes: [NativeInkStroke] = []
    for (index, stroke) in drawing.strokes.enumerated() {
      var points: [NativeInkPoint] = []
      for point in stroke.path.interpolatedPoints(by: .distance(2)) {
        let location = point.location.applying(stroke.transform)
        guard location.x.isFinite, location.y.isFinite else { return nil }
        guard points.count < maximumStrokePoints else {
          throw PDFSourceInkEncodingError.strokeTooDetailed
        }
        points.append(
          NativeInkPoint(
            x: Double(location.x), y: Double(location.y), pressure: Double(point.force)))
        count += 1
        guard count <= maximumPoints else {
          throw PDFSourceInkEncodingError.tooManyPoints
        }
      }
      guard !points.isEmpty else { return nil }
      let scale = hypot(stroke.transform.a, stroke.transform.b)
      let width = max(0.25, Double(stroke.path.first?.size.width ?? 3) * Double(scale))
      let identity =
        previous?.strokes.indices.contains(index) == true
        ? previous!.strokes[index].id : UUID().uuidString
      strokes.append(
        NativeInkStroke(id: identity, points: points, color: hex(stroke.ink.color), width: width))
    }
    return NativeAnnotationDrawing(
      format: "bookorbit-ink-v1", strokes: strokes, nativeData: encoded)
  }

  static func fixture() -> PKDrawing {
    let points = [CGPoint(x: 80, y: 80), CGPoint(x: 120, y: 90), CGPoint(x: 160, y: 120)]
      .enumerated().map { index, point in
        PKStrokePoint(
          location: point, timeOffset: Double(index) * 0.1,
          size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
      }
    return PKDrawing(strokes: [
      PKStroke(
        ink: PKInk(.pen, color: .black),
        path: PKStrokePath(controlPoints: points, creationDate: .distantPast))
    ])
  }

  private static func color(_ value: String) -> UIColor {
    let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
    guard digits.count == 6, let number = UInt32(digits, radix: 16) else { return .label }
    return UIColor(
      red: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255,
      blue: CGFloat(number & 255) / 255, alpha: 1)
  }

  private static func hex(_ value: UIColor) -> String {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    value.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
  }
}

enum PDFSourceInkEncodingError: LocalizedError {
  case tooLarge, strokeTooDetailed, tooManyPoints, tooManyStrokes

  var errorDescription: String? {
    switch self {
    case .tooLarge:
      "This ink group is too large to sync. Undo or erase some strokes and retry. Your drawing remains on this page."
    case .strokeTooDetailed:
      "A stroke exceeds 10,000 points. Undo or erase that stroke, then draw shorter strokes and retry. Your drawing remains on this page."
    case .tooManyPoints:
      "This ink group has too many points. Undo or erase some strokes, then save smaller groups. Your drawing remains on this page."
    case .tooManyStrokes:
      "This ink group exceeds 1,000 strokes. Undo or erase some strokes, then save smaller groups. Your drawing remains on this page."
    }
  }
}
