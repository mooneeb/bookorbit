import Foundation

struct NativeEPUBTextDocument: Sendable {
  let source: NativeEPUBSource
  let text: String
  let language: String?
  let segments: [NativeEPUBTextSegment]

  static func build(_ source: NativeEPUBSource) throws -> Self {
    let root = source.elements[0]
    guard root.name == "html", root.namespace == "http://www.w3.org/1999/xhtml",
      let body = root.children.compactMap({ child -> Int? in
        if case .element(let index, _) = child, source.elements[index].name == "body" {
          return index
        }
        return nil
      }).first
    else { throw NativeEPUBError.unsupported }
    var projection = NativeEPUBTextProjection(source: source)
    var paragraphs = 0
    for child in source.elements[body].children {
      switch child {
      case .text(let value, _):
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw NativeEPUBError.unsupported
        }
      case .element(let index, _):
        guard paragraphs < 128, source.elements[index].name == "p" else {
          throw NativeEPUBError.unsupported
        }
        if paragraphs > 0 { try projection.separator() }
        let before = projection.segments.count
        try projection.append(element: index, block: index, bold: false, italic: false)
        guard before < projection.segments.count else { throw NativeEPUBError.unsupported }
        paragraphs += 1
      }
    }
    guard paragraphs > 0 else { throw NativeEPUBError.invalidPublication }
    return Self(
      source: source, text: projection.text,
      language: root.attributes["xml:lang"] ?? root.attributes["lang"],
      segments: projection.segments)
  }

  func range(for cfi: NativeEPUBCFI) throws -> NSRange {
    let start = try displayOffset(for: cfi.start)
    let end = try cfi.end.map(displayOffset) ?? start
    guard start <= end else { throw NativeEPUBError.invalidAnchor }
    let range = NSRange(location: start, length: end - start)
    _ = try endpoints(for: range)
    return range
  }

  func anchor(for range: NSRange, package: [NativeCFIStep]) throws -> NativeEPUBCFI {
    let (start, end) = try endpoints(for: range)
    return NativeEPUBCFI(package: package, start: start, end: range.length == 0 ? nil : end)
  }

  func selectedText(in range: NSRange) throws -> String {
    _ = try endpoints(for: range)
    return (text as NSString).substring(with: range)
  }

  private func displayOffset(for endpoint: NativeCFIEndpoint) throws -> Int {
    let element = try source.element(at: Array(endpoint.path.dropLast()))
    guard let step = endpoint.path.last,
      let segment = segments.first(where: { $0.element == element && $0.step == step.index }),
      endpoint.offset <= segment.range.length
    else { throw NativeEPUBError.invalidAnchor }
    return segment.range.location + endpoint.offset
  }

  private func endpoints(for range: NSRange) throws -> (NativeCFIEndpoint, NativeCFIEndpoint) {
    let count = text.utf16.count
    guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
      range.location <= count, range.length <= count - range.location
    else { throw NativeEPUBError.unmappedSelection }
    let end = range.location + range.length
    let startSegment =
      segments.first {
        range.location >= $0.range.location && range.location < NSMaxRange($0.range)
      } ?? segments.last.flatMap { NSMaxRange($0.range) == range.location ? $0 : nil }
    let endSegment =
      range.length == 0
      ? startSegment
      : segments.last(where: { end > $0.range.location && end <= NSMaxRange($0.range) })
    guard let startSegment, let endSegment, startSegment.block == endSegment.block,
      validUTF16Boundary(range.location), validUTF16Boundary(end)
    else { throw NativeEPUBError.unmappedSelection }
    let start = NativeCFIEndpoint(
      path: try source.path(to: startSegment.element)
        + [NativeCFIStep(index: startSegment.step, assertion: nil)],
      offset: range.location - startSegment.range.location)
    let finish = NativeCFIEndpoint(
      path: try source.path(to: endSegment.element)
        + [NativeCFIStep(index: endSegment.step, assertion: nil)],
      offset: end - endSegment.range.location)
    return (start, finish)
  }

  private func validUTF16Boundary(_ offset: Int) -> Bool {
    let source = text as NSString
    guard offset > 0, offset < source.length else { return true }
    return
      !((0xD800...0xDBFF).contains(source.character(at: offset - 1))
      && (0xDC00...0xDFFF).contains(source.character(at: offset)))
  }
}

struct NativeEPUBTextSegment: Sendable {
  let range: NSRange
  let element: Int
  let step: Int
  let block: Int
  let bold: Bool
  let italic: Bool
}

private struct NativeEPUBTextProjection {
  let source: NativeEPUBSource
  private(set) var text = ""
  private(set) var segments: [NativeEPUBTextSegment] = []
  private var units = 0

  init(source: NativeEPUBSource) { self.source = source }

  mutating func separator() throws {
    guard units <= 32_768 - 2 else { throw NativeEPUBError.tooLarge }
    text += "\n\n"
    units += 2
  }

  mutating func append(element: Int, block: Int, bold: Bool, italic: Bool) throws {
    let node = source.elements[element]
    guard node.namespace == "http://www.w3.org/1999/xhtml",
      ["p", "span", "em", "strong", "b", "i"].contains(node.name)
    else { throw NativeEPUBError.unsupported }
    let bold = bold || ["strong", "b"].contains(node.name)
    let italic = italic || ["em", "i"].contains(node.name)
    for child in node.children {
      switch child {
      case .element(let index, _):
        try append(element: index, block: block, bold: bold, italic: italic)
      case .text(let value, let step):
        let count = value.utf16.count
        guard count <= 32_768 - units, segments.count < 4096 else {
          throw NativeEPUBError.tooLarge
        }
        segments.append(
          NativeEPUBTextSegment(
            range: NSRange(location: units, length: count), element: element, step: step,
            block: block, bold: bold, italic: italic))
        text += value
        units += count
      }
    }
  }
}
