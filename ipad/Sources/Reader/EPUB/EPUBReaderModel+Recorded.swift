import Foundation

struct EPUBRecordedSegment: Codable, Sendable {
  let cfi: String
  let chapterIndex: Int
  let text: String
}

extension EPUBReaderModel {
  func recordedMatch(_ items: [EpubMediaOverlayClip], cfi: String) async throws -> Int? {
    guard isReady, !isNavigating, items.count <= 128, NativeTTSPositionModel.validCFI(cfi) else {
      throw ConnectionError.invalidResponse
    }
    let data = try JSONEncoder().encode(items)
    let raw = try await publicationCommand(
      "return await window.epubRecordedMatch(items, cfi)",
      arguments: ["items": JSONSerialization.jsonObject(with: data), "cfi": cfi])
    if raw == nil || raw is NSNull { return nil }
    guard let index = raw as? Int, items.contains(where: { $0.index == index }) else {
      throw ConnectionError.invalidResponse
    }
    return index
  }

  func highlightRecorded(_ clip: EpubMediaOverlayClip, follow: Bool) async throws
    -> EPUBRecordedSegment
  {
    guard isReady, !isNavigating, EPUBPublicationResources.validPath(clip.textHref),
      clip.textFragment.map({ !$0.contains("#") && $0.utf16.count <= 4096 }) ?? true
    else { throw ConnectionError.invalidResponse }
    let target = clip.textFragment.map { "\(clip.textHref)#\($0)" } ?? clip.textHref
    let raw = try await publicationCommand(
      "return await window.epubRecordedHighlight(href, follow)",
      arguments: ["href": target, "follow": follow])
    let data = try JSONSerialization.data(withJSONObject: raw as Any)
    guard data.count <= 16 * 1024 else { throw ConnectionError.invalidResponse }
    let segment = try JSONDecoder().decode(EPUBRecordedSegment.self, from: data)
    guard NativeTTSPositionModel.validCFI(segment.cfi), segment.chapterIndex == clip.sectionIndex,
      segment.text.utf16.count <= 500
    else { throw ConnectionError.invalidResponse }
    return segment
  }

  func clearRecordedHighlight() async {
    _ = try? await publicationCommand("window.epubClearRecordedHighlight()", arguments: [:])
  }
}
