import Foundation

struct NativeCFIStep: Sendable, Equatable {
  let index: Int
  let assertion: String?

  var encoded: String {
    let suffix = assertion.map { "[\(Self.escape($0))]" } ?? ""
    return "/\(index)\(suffix)"
  }

  private static func escape(_ value: String) -> String {
    value.reduce(into: "") { result, character in
      if "^[](),;=".contains(character) { result.append("^") }
      result.append(character)
    }
  }
}

struct NativeCFIEndpoint: Sendable, Equatable {
  let path: [NativeCFIStep]
  let offset: Int

  var encoded: String { path.map(\.encoded).joined() + ":\(offset)" }
}

struct NativeEPUBCFI: Sendable {
  let package: [NativeCFIStep]
  let start: NativeCFIEndpoint
  let end: NativeCFIEndpoint?

  static func parse(_ value: String) throws -> Self {
    guard value.utf16.count <= AnnotationVocabulary.cfiMaximum,
      value.hasPrefix("epubcfi("), value.hasSuffix(")")
    else {
      throw NativeEPUBError.invalidAnchor
    }
    var parser = NativeCFIParser(characters: Array(value.dropFirst(8).dropLast()))
    let package = try parser.path()
    guard !package.isEmpty, package.allSatisfy({ $0.index.isMultiple(of: 2) }) else {
      throw NativeEPUBError.unsupported
    }
    try parser.require("!")
    let common = try parser.path()
    if parser.take(":") {
      let start = NativeCFIEndpoint(path: common, offset: try parser.integer())
      try parser.requireEnd()
      try validate(start)
      return Self(package: package, start: start, end: nil)
    }
    try parser.require(",")
    let startPath = common + (try parser.path())
    try parser.require(":")
    let start = NativeCFIEndpoint(path: startPath, offset: try parser.integer())
    try parser.require(",")
    let endPath = common + (try parser.path())
    try parser.require(":")
    let end = NativeCFIEndpoint(path: endPath, offset: try parser.integer())
    try parser.requireEnd()
    try validate(start)
    try validate(end)
    return Self(package: package, start: start, end: end)
  }

  var encoded: String {
    let top = package.map(\.encoded).joined() + "!"
    guard let end else { return "epubcfi(\(top)\(start.encoded))" }
    var common = 0
    let maximum = max(0, min(start.path.count, end.path.count) - 1)
    while common < maximum, start.path[common] == end.path[common] { common += 1 }
    let parent = start.path.prefix(common).map(\.encoded).joined()
    let from = start.path.dropFirst(common).map(\.encoded).joined() + ":\(start.offset)"
    let to = end.path.dropFirst(common).map(\.encoded).joined() + ":\(end.offset)"
    return "epubcfi(\(top)\(parent),\(from),\(to))"
  }

  private static func validate(_ endpoint: NativeCFIEndpoint) throws {
    guard !endpoint.path.isEmpty, endpoint.path.count <= 64,
      endpoint.path.dropLast().allSatisfy({ $0.index.isMultiple(of: 2) }),
      let last = endpoint.path.last, !last.index.isMultiple(of: 2), last.assertion == nil,
      (0...131_072).contains(endpoint.offset)
    else { throw NativeEPUBError.unsupported }
  }
}

private struct NativeCFIParser {
  let characters: [Character]
  private var cursor = 0

  init(characters: [Character]) { self.characters = characters }

  mutating func path() throws -> [NativeCFIStep] {
    var result: [NativeCFIStep] = []
    while take("/") {
      guard result.count < 64 else { throw NativeEPUBError.tooLarge }
      let index = try integer()
      guard (1...8193).contains(index) else { throw NativeEPUBError.unsupported }
      let assertion = take("[") ? try assertion() : nil
      result.append(NativeCFIStep(index: index, assertion: assertion))
    }
    return result
  }

  mutating func integer() throws -> Int {
    let start = cursor
    var value = 0
    while cursor < characters.count, let digit = characters[cursor].asciiValue,
      (48...57).contains(digit)
    {
      guard cursor - start < 6 else { throw NativeEPUBError.tooLarge }
      value = value * 10 + Int(digit - 48)
      cursor += 1
    }
    guard cursor > start, cursor - start == 1 || characters[start] != "0" else {
      throw NativeEPUBError.invalidAnchor
    }
    return value
  }

  mutating func take(_ character: Character) -> Bool {
    guard cursor < characters.count, characters[cursor] == character else { return false }
    cursor += 1
    return true
  }

  mutating func require(_ character: Character) throws {
    guard take(character) else { throw NativeEPUBError.unsupported }
  }

  func requireEnd() throws {
    guard cursor == characters.count else { throw NativeEPUBError.unsupported }
  }

  private mutating func assertion() throws -> String {
    var result = ""
    while cursor < characters.count {
      if take("]") {
        guard !result.isEmpty else { throw NativeEPUBError.invalidAnchor }
        return result
      }
      let character = characters[cursor]
      cursor += 1
      if character == "^" {
        guard cursor < characters.count, "^[](),;=".contains(characters[cursor]) else {
          throw NativeEPUBError.unsupported
        }
        result.append(characters[cursor])
        cursor += 1
      } else {
        guard !"[(),;=".contains(character) else { throw NativeEPUBError.unsupported }
        result.append(character)
      }
      guard result.utf16.count <= 1024 else { throw NativeEPUBError.tooLarge }
    }
    throw NativeEPUBError.invalidAnchor
  }
}
