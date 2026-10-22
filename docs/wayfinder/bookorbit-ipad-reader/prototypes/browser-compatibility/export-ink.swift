import AppKit
import CryptoKit
import Foundation
import PencilKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
  fatalError("Usage: swift export-ink.swift input.drawing output.png")
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let original = try Data(contentsOf: input)
let drawing = try PKDrawing(data: original)
let crop = drawing.bounds.insetBy(dx: -12, dy: -12).integral
guard !drawing.strokes.isEmpty, crop.width > 0, crop.height > 0,
  crop.width <= 4096, crop.height <= 4096
else { fatalError("The scratch drawing is empty or exceeds this export's bounds.") }
var image: NSImage?
NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
  image = drawing.image(from: crop, scale: 2)
}
guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
  let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
else { fatalError("Native ink rendering failed.") }
try png.write(to: output, options: .atomic)
let hash = { (data: Data) in SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
guard try Data(contentsOf: input) == original else { fatalError("Original drawing changed.") }
let record: [String: Any] = [
  "originalSha256": hash(original), "previewSha256": hash(png),
  "strokeCount": drawing.strokes.count,
  "crop": ["x": crop.minX, "y": crop.minY, "width": crop.width, "height": crop.height],
  "pixels": ["width": cgImage.width, "height": cgImage.height],
  "renderer": "macOS PencilKit from unchanged iPad PKDrawing; not a fresh iPad render",
]
let data = try JSONSerialization.data(
  withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
try data.write(to: output.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
print(String(data: data, encoding: .utf8)!)
