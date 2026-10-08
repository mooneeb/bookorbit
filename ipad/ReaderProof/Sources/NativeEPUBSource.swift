import Foundation

struct NativeEPUBSource: Sendable {
  let elements: [NativeEPUBElement]

  static func parse(_ data: Data, limit: Int) throws -> Self {
    guard !data.isEmpty, data.count <= limit else { throw NativeEPUBError.tooLarge }
    guard let source = String(data: data, encoding: .utf8), !source.contains("\u{0}"),
      source.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil
    else { throw NativeEPUBError.unsupported }
    let delegate = NativeEPUBSourceParser()
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = delegate
    guard parser.parse(), delegate.failure == nil, !delegate.elements.isEmpty else {
      throw delegate.failure ?? NativeEPUBError.invalidPublication
    }
    return Self(elements: delegate.elements)
  }

  func path(to index: Int) throws -> [NativeCFIStep] {
    guard elements.indices.contains(index) else { throw NativeEPUBError.invalidAnchor }
    var result: [NativeCFIStep] = []
    var cursor = index
    while let parent = elements[cursor].parent {
      let element = elements[cursor]
      result.append(NativeCFIStep(index: element.step, assertion: element.attributes["id"]))
      cursor = parent
    }
    return result.reversed()
  }

  func element(at path: [NativeCFIStep]) throws -> Int {
    var cursor = 0
    for step in path {
      guard step.index > 0, step.index.isMultiple(of: 2),
        let child = elements[cursor].children.first(where: { $0.step == step.index }),
        case .element(let index, _) = child,
        step.assertion == nil || elements[index].attributes["id"] == step.assertion
      else { throw NativeEPUBError.invalidAnchor }
      cursor = index
    }
    return cursor
  }
}

struct NativeEPUBElement: Sendable {
  let parent: Int?
  let step: Int
  let name: String
  let namespace: String?
  let attributes: [String: String]
  var children: [NativeEPUBChild] = []
}

enum NativeEPUBChild: Sendable {
  case element(Int, step: Int)
  case text(String, step: Int)

  var step: Int {
    switch self {
    case .element(_, let step), .text(_, let step): step
    }
  }
}

enum NativeEPUBError: LocalizedError {
  case tooLarge, unsupported, invalidPublication, invalidAnchor, unmappedSelection

  var errorDescription: String? {
    switch self {
    case .tooLarge: "This publication exceeds the native anchor proof's size limit."
    case .unsupported: "This content or location is not supported by the native anchor proof."
    case .invalidPublication: "The delivered publication could not be read."
    case .invalidAnchor: "This location does not match the delivered publication."
    case .unmappedSelection: "Select one continuous passage inside a supported paragraph."
    }
  }
}

private final class NativeEPUBSourceParser: NSObject, XMLParserDelegate {
  private(set) var elements: [NativeEPUBElement] = []
  private(set) var failure: NativeEPUBError?
  private var stack: [Int] = []
  private var childCounts: [Int: Int] = [:]
  private var ids: Set<String> = []
  private var textUnits = 0

  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes: [String: String]
  ) {
    guard stack.count < 64, elements.count < 4096, attributes.count <= 64,
      attributes.allSatisfy({ $0.key.utf16.count <= 256 && $0.value.utf16.count <= 4096 })
    else { return fail(.tooLarge, parser) }
    if let id = attributes["id"] {
      guard !id.isEmpty, id.utf16.count <= 1024, ids.insert(id).inserted else {
        return fail(.invalidPublication, parser)
      }
    }
    let index = elements.count
    let parent = stack.last
    var step = 0
    if let parent {
      let count = (childCounts[parent] ?? 0) + 1
      childCounts[parent] = count
      step = count * 2
      elements[parent].children.append(.element(index, step: step))
    }
    elements.append(
      NativeEPUBElement(
        parent: parent, step: step, name: name, namespace: namespaceURI, attributes: attributes))
    stack.append(index)
  }

  func parser(_ parser: XMLParser, foundCharacters text: String) {
    guard let parent = stack.last, !text.isEmpty else { return }
    let count = text.utf16.count
    guard count <= 131_072 - textUnits else { return fail(.tooLarge, parser) }
    textUnits += count
    if let last = elements[parent].children.last, case .text(let preceding, let step) = last {
      elements[parent].children[elements[parent].children.count - 1] = .text(
        preceding + text, step: step)
    } else {
      let step = (childCounts[parent] ?? 0) * 2 + 1
      elements[parent].children.append(.text(text, step: step))
    }
  }

  func parser(_ parser: XMLParser, foundCDATA data: Data) {
    guard let text = String(data: data, encoding: .utf8) else {
      return fail(.invalidPublication, parser)
    }
    self.parser(parser, foundCharacters: text)
  }

  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    stack.removeLast()
  }

  private func fail(_ error: NativeEPUBError, _ parser: XMLParser) {
    failure = error
    parser.abortParsing()
  }
}
