import Foundation
import UIKit

extension NSAttributedString.Key {
  static let descriptionBold = Self("BookOrbit.description.bold")
  static let descriptionItalic = Self("BookOrbit.description.italic")
  static let descriptionUnderline = Self("BookOrbit.description.underline")
  static let descriptionStrike = Self("BookOrbit.description.strike")
  static let descriptionPath = Self("BookOrbit.description.path")
}

@MainActor
enum RichDescriptionHTML {
  static let maximumHTMLBytes = 256 * 1024
  static let maximumTextLength = 128 * 1024
  static let maximumDepth = 16

  static func decode(_ html: String) -> NSAttributedString? {
    guard html.utf8.count <= maximumHTMLBytes else { return nil }
    let parser = DescriptionHTMLParser(html)
    guard let text = parser.parse(), text.length <= maximumTextLength,
      paragraphRanges(text.string).count <= 4096
    else { return nil }
    restyle(text)
    return text
  }

  static func encode(_ text: NSAttributedString) -> String {
    guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
    var html = ""
    var open: [String] = []
    for range in paragraphRanges(text.string) {
      let path = path(in: text, at: range.location)
      let shared = zip(open, path).prefix(while: { $0.0 == $0.1 }).count
      for component in open.dropFirst(shared).reversed() { html += "</\(tag(component))>" }
      for component in path.dropFirst(shared) { html += "<\(tag(component))>" }
      open = path
      html += "<p>"
      text.enumerateAttributes(in: range) { attributes, run, _ in
        var value = escape((text.string as NSString).substring(with: run))
          .replacingOccurrences(of: "\u{2028}", with: "<br>")
        for (key, name) in marks.reversed() where attributes[key] as? Bool == true {
          value = "<\(name)>\(value)</\(name)>"
        }
        if let url = attributes[.link] as? URL,
          allowedURL(url.absoluteString, allowRelative: true) != nil
        {
          value = "<a href=\"\(escape(url.absoluteString))\">\(value)</a>"
        }
        html += value
      }
      html += "</p>"
    }
    for component in open.reversed() { html += "</\(tag(component))>" }
    return html
  }

  static let marks: [(NSAttributedString.Key, String)] = [
    (.descriptionBold, "strong"), (.descriptionItalic, "em"),
    (.descriptionUnderline, "u"), (.descriptionStrike, "s"),
  ]

  static func allowedURL(_ raw: String, allowRelative: Bool = false) -> URL? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 8192,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      let url = URL(string: value)
    else { return nil }
    guard let scheme = url.scheme?.lowercased() else { return allowRelative ? url : nil }
    guard ["https", "http", "mailto"].contains(scheme) else { return nil }
    if scheme != "mailto", url.host?.isEmpty != false { return nil }
    return url
  }

  static func linkURL(_ raw: String) -> URL? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasScheme = value.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil
    return allowedURL(hasScheme ? value : "https://\(value)")
  }

  static func path(in text: NSAttributedString, at location: Int) -> [String] {
    guard text.length > 0 else { return [] }
    return text.attribute(.descriptionPath, at: min(location, text.length - 1), effectiveRange: nil)
      as? [String] ?? []
  }

  static func paragraphRanges(_ string: String) -> [NSRange] {
    let source = string as NSString
    var ranges: [NSRange] = []
    var start = 0
    for index in 0..<source.length where source.character(at: index) == 10 {
      ranges.append(NSRange(location: start, length: index - start))
      start = index + 1
    }
    ranges.append(NSRange(location: start, length: source.length - start))
    return ranges
  }

  static func attributes(_ semantic: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]
  {
    var attributes = semantic
    var traits: UIFontDescriptor.SymbolicTraits = []
    if semantic[.descriptionBold] as? Bool == true { traits.insert(.traitBold) }
    if semantic[.descriptionItalic] as? Bool == true { traits.insert(.traitItalic) }
    let base = UIFont.preferredFont(forTextStyle: .body)
    let descriptor = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
    attributes[.font] = UIFont(descriptor: descriptor, size: base.pointSize)
    attributes[.foregroundColor] = UIColor.label
    attributes[.underlineStyle] = semantic[.descriptionUnderline] as? Bool == true ? 1 : 0
    attributes[.strikethroughStyle] = semantic[.descriptionStrike] as? Bool == true ? 1 : 0
    let path = semantic[.descriptionPath] as? [String] ?? []
    let lists = path.filter { $0 == "ul" || $0 == "ol" }.count
    let quotes = path.filter { $0 == "blockquote" }.count
    let style = NSMutableParagraphStyle()
    style.paragraphSpacing = base.lineHeight * 0.35
    style.headIndent = CGFloat(lists + quotes) * base.lineHeight
    style.firstLineHeadIndent = style.headIndent
    style.lineBreakMode = .byWordWrapping
    attributes[.paragraphStyle] = style
    return attributes
  }

  static func restyle(_ text: NSMutableAttributedString) {
    var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
    text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) {
      attributes, range, _ in
      runs.append((range, self.attributes(attributes)))
    }
    for (range, attributes) in runs { text.setAttributes(attributes, range: range) }
  }

  private static func tag(_ component: String) -> String {
    component.hasPrefix("li:") ? "li" : component
  }

  private static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }
}

@MainActor
private final class DescriptionHTMLParser {
  private let source: NSString
  private let output = NSMutableAttributedString(string: "")
  private var frames: [(name: String, attributes: [NSAttributedString.Key: Any])] = []
  private var semantic: [NSAttributedString.Key: Any] = [:]
  private var path: [String] = []
  private var suppressed: [String] = []
  private var pendingParagraph = false
  private var itemID = 0
  private var tokenCount = 0

  init(_ html: String) { source = html as NSString }

  func parse() -> NSMutableAttributedString? {
    var index = 0
    while index < source.length {
      if source.character(at: index) != 60 {
        let start = index
        while index < source.length, source.character(at: index) != 60 { index += 1 }
        if suppressed.isEmpty {
          append(source.substring(with: NSRange(location: start, length: index - start)))
        }
        continue
      }
      let start = index
      if source.length - index >= 4,
        source.substring(with: NSRange(location: index, length: 4)) == "<!--"
      {
        let end = source.range(
          of: "-->", range: NSRange(location: index + 4, length: source.length - index - 4))
        index = end.location == NSNotFound ? source.length : NSMaxRange(end)
        continue
      }
      index += 1
      var quote: unichar = 0
      while index < source.length {
        let character = source.character(at: index)
        if quote != 0 {
          if character == quote { quote = 0 }
        } else if character == 34 || character == 39 {
          quote = character
        } else if character == 62 {
          break
        }
        index += 1
      }
      guard index < source.length else {
        if suppressed.isEmpty { append(source.substring(from: start)) }
        break
      }
      let token = source.substring(with: NSRange(location: start + 1, length: index - start - 1))
      index += 1
      tokenCount += 1
      guard tokenCount <= 16384 else { return nil }
      consume(token)
      guard tokenCount <= 16384,
        frames.count + path.count <= RichDescriptionHTML.maximumDepth * 2,
        output.length <= RichDescriptionHTML.maximumTextLength
      else { return nil }
    }
    return output
  }

  private func consume(_ token: String) {
    let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
    let closing = value.hasPrefix("/")
    let body = closing ? String(value.dropFirst()) : value
    let name = String(body.prefix(while: { $0.isLetter || $0.isNumber })).lowercased()
    guard !name.isEmpty else { return }
    if ["script", "style", "iframe", "object", "svg", "math", "template", "head"].contains(name) {
      if closing {
        if let index = suppressed.lastIndex(of: name) { suppressed.removeSubrange(index...) }
      } else {
        suppressed.append(name)
      }
      return
    }
    guard suppressed.isEmpty else { return }
    if name == "br", !closing {
      append("\u{2028}", decodeEntities: false)
      return
    }
    if ["p", "li", "ul", "ol", "blockquote"].contains(name) {
      pendingParagraph = output.length > 0
      if name == "p" { return }
      if closing {
        let index = path.lastIndex(where: { name == "li" ? $0.hasPrefix("li:") : $0 == name })
        if let index { path.removeSubrange(index...) }
      } else {
        guard path.count < RichDescriptionHTML.maximumDepth else {
          tokenCount = 16385
          return
        }
        if name == "li" {
          itemID += 1
          path.append("li:\(itemID)")
        } else {
          path.append(name)
        }
      }
      return
    }
    let key: NSAttributedString.Key?
    switch name {
    case "b", "strong": key = .descriptionBold
    case "i", "em": key = .descriptionItalic
    case "u": key = .descriptionUnderline
    case "s", "strike": key = .descriptionStrike
    case "a": key = .link
    default: return
    }
    if closing {
      if let index = frames.lastIndex(where: { $0.name == name }) {
        semantic = frames[index].attributes
        frames.removeSubrange(index...)
      }
    } else {
      frames.append((name, semantic))
      if let key {
        if key == .link {
          semantic[key] = href(in: body).flatMap {
            RichDescriptionHTML.allowedURL($0, allowRelative: true)
          }
        } else {
          semantic[key] = true
        }
      }
    }
  }

  private func append(_ raw: String, decodeEntities: Bool = true) {
    var value = decodeEntities ? RichDescriptionEntities.decode(raw) : raw
    if decodeEntities {
      value = value.replacingOccurrences(of: "[\t\r\n ]+", with: " ", options: .regularExpression)
      if pendingParagraph || output.length == 0 {
        value = value.replacingOccurrences(of: "^ +", with: "", options: .regularExpression)
      }
    }
    guard !value.isEmpty else { return }
    if pendingParagraph {
      let previous =
        output.length > 0 ? output.attributes(at: output.length - 1, effectiveRange: nil) : [:]
      output.append(NSAttributedString(string: "\n", attributes: previous))
      pendingParagraph = false
    }
    var attributes = semantic
    attributes[.descriptionPath] = path
    output.append(NSAttributedString(string: value, attributes: attributes))
  }

  private func href(in token: String) -> String? {
    guard
      let regex = try? NSRegularExpression(
        pattern: #"(?:^|\s)href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'`=<>]+))"#,
        options: .caseInsensitive),
      let match = regex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token))
    else { return nil }
    for index in 1...3 {
      if let range = Range(match.range(at: index), in: token) {
        return RichDescriptionEntities.decode(String(token[range]))
      }
    }
    return nil
  }
}
