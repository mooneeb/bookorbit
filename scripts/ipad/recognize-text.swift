import Foundation
import Vision

guard CommandLine.arguments.count == 2 else {
  throw NSError(
    domain: "BookOrbitScreenshot", code: 1,
    userInfo: [NSLocalizedDescriptionKey: "Provide one captured PNG path."])
}
let request = VNRecognizeTextRequest()
request.revision = VNRecognizeTextRequestRevision3
request.recognitionLevel = .accurate
request.minimumTextHeight = 0.005
request.recognitionLanguages = ["en-US"]
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(url: URL(fileURLWithPath: CommandLine.arguments[1]))
try handler.perform([request])
let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
let data = try JSONEncoder().encode(lines)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
