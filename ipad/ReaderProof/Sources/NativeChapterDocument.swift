import Foundation

struct NativeChapterDocument: Sendable {
  let text: String
  let language: String?

  static func parse(_ data: Data) throws -> NativeChapterDocument {
    guard data.count <= 64 * 1024 else { throw NativeChapterError.tooLarge }
    guard let source = String(data: data, encoding: .utf8),
      !source.contains("\u{0}"),
      source.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil
    else { throw NativeChapterError.unsupported }
    let delegate = NativeChapterParser()
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = delegate
    guard parser.parse(), delegate.failure == nil, delegate.sawBody,
      !delegate.paragraphs.isEmpty
    else { throw delegate.failure ?? NativeChapterError.invalid }
    return NativeChapterDocument(
      text: delegate.paragraphs.joined(separator: "\n\n"), language: delegate.language)
  }
}

enum NativeChapterError: LocalizedError {
  case tooLarge
  case unsupported
  case invalid

  var errorDescription: String? {
    switch self {
    case .tooLarge: "This chapter exceeds the native diagnostic's size limit."
    case .unsupported: "This diagnostic supports only plain XHTML paragraphs."
    case .invalid: "The delivered chapter could not be read."
    }
  }
}

private final class NativeChapterParser: NSObject, XMLParserDelegate {
  private(set) var paragraphs: [String] = []
  private(set) var language: String?
  private(set) var sawBody = false
  private(set) var failure: NativeChapterError?
  private var elements: [String] = []
  private var paragraph: String?
  private var paragraphUnits = 0
  private var textUnits = 0

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String]
  ) {
    guard elements.count < 64 else { return fail(.tooLarge, parser: parser) }
    guard namespaceURI == "http://www.w3.org/1999/xhtml" else {
      return fail(.unsupported, parser: parser)
    }
    if ["html", "head", "body"].contains(elementName), !elements.isEmpty {
      guard elementName != "html", elements == ["html"] else {
        return fail(.unsupported, parser: parser)
      }
    }
    if elements.isEmpty {
      guard elementName == "html" else { return fail(.invalid, parser: parser) }
      let language = attributeDict["xml:lang"] ?? attributeDict["lang"]
      self.language = language.flatMap { $0.utf16.count <= 64 ? $0 : nil }
    } else if elements.contains("body") {
      guard elements.last == "body", elementName == "p" else {
        return fail(.unsupported, parser: parser)
      }
      guard paragraphs.count < 128 else { return fail(.tooLarge, parser: parser) }
      paragraph = ""
      paragraphUnits = 0
    } else if elements.last == "html" {
      guard ["head", "body"].contains(elementName) else {
        return fail(.unsupported, parser: parser)
      }
      if elementName == "body" {
        guard !sawBody else { return fail(.invalid, parser: parser) }
        sawBody = true
      }
    }
    elements.append(elementName)
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if paragraph != nil {
      let separatorUnits = paragraphs.isEmpty ? 0 : 2
      let units = string.utf16.count
      guard textUnits + separatorUnits + paragraphUnits + units <= 32_768
      else { return fail(.tooLarge, parser: parser) }
      paragraph?.append(string)
      paragraphUnits += units
    } else if elements.contains("body"),
      !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      fail(.unsupported, parser: parser)
    }
  }

  func parser(_ parser: XMLParser, foundCDATA block: Data) {
    guard let text = String(data: block, encoding: .utf8) else {
      return fail(.invalid, parser: parser)
    }
    self.parser(parser, foundCharacters: text)
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "p", let paragraph {
      textUnits += paragraphUnits + (paragraphs.isEmpty ? 0 : 2)
      paragraphs.append(paragraph)
      self.paragraph = nil
    }
    if !elements.isEmpty { elements.removeLast() }
  }

  private func fail(_ error: NativeChapterError, parser: XMLParser) {
    if failure == nil { failure = error }
    parser.abortParsing()
  }
}
