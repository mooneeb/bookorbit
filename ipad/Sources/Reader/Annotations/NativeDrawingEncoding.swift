import PencilKit
import UIKit

@MainActor enum NativeDrawingEncoding {
  static func encode(_ drawing: PKDrawing, prior: NativeAnnotationDrawing? = nil) throws
    -> NativeAnnotationDrawing
  {
    let data = drawing.dataRepresentation()
    guard !drawing.strokes.isEmpty, drawing.strokes.count <= 256,
      drawing.strokes.reduce(0, { $0 + $1.path.count }) <= 10_000, data.count <= 1_400_000
    else { throw NativeDrawingEncodingError.unsupportedSize }
    var total = 0
    let strokes = try drawing.strokes.enumerated().map { index, stroke in
      var points: [NativeInkPoint] = []
      for point in stroke.path.interpolatedPoints(by: .distance(2)) {
        total += 1
        guard total <= 10_000 else { throw NativeDrawingEncodingError.unsupportedSize }
        let location = point.location.applying(stroke.transform)
        guard location.x.isFinite, location.y.isFinite else {
          throw NativeDrawingEncodingError.invalidDrawing
        }
        points.append(
          NativeInkPoint(
            x: Double(location.x), y: Double(location.y),
            pressure: min(1, max(0, Double(point.force)))))
      }
      let scale = hypot(stroke.transform.a, stroke.transform.b)
      let width = Double(stroke.path.first?.size.width ?? 3) * Double(scale)
      guard !points.isEmpty, width.isFinite, width > 0, width <= 100 else {
        throw NativeDrawingEncodingError.invalidDrawing
      }
      let identity =
        prior?.strokes.indices.contains(index) == true
        ? prior!.strokes[index].id : UUID().uuidString
      return NativeInkStroke(
        id: identity, points: points, color: hex(stroke.ink.color), width: max(0.01, width))
    }
    return NativeAnnotationDrawing(
      format: "bookorbit-ink-v1", strokes: strokes, nativeData: data.base64EncodedString())
  }

  private static func hex(_ color: UIColor) -> String {
    let resolved = color.resolvedColor(with: .current)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    let channel: (CGFloat) -> Int = { Int((min(1, max(0, $0)) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
  }
}

enum NativeDrawingEncodingError: LocalizedError {
  case unsupportedSize, invalidDrawing
  var errorDescription: String? {
    switch self {
    case .unsupportedSize:
      "This passage drawing is too large to synchronize. Keep a smaller drawing with up to 256 strokes and 10,000 points."
    case .invalidDrawing:
      "This passage drawing contains unsupported geometry. Your retained drawing remains available for editing."
    }
  }
}
