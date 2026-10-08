import Foundation

enum FieldUpdate<Value: Encodable & Sendable & Equatable>: Encodable, Sendable, Equatable {
  case clear
  case set(Value)

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .clear: try container.encodeNil()
    case .set(let value): try container.encode(value)
    }
  }
}

extension FieldUpdate: Decodable where Value: Decodable {
  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self = try container.decodeNil() ? .clear : .set(container.decode(Value.self))
  }
}

extension KeyedDecodingContainer {
  // Sparse previews distinguish an offered clear from a field the source did not provide.
  func decodeIfPresent<Value>(_ type: FieldUpdate<Value>.Type, forKey key: Key) throws
    -> FieldUpdate<Value>? where Value: Codable & Sendable & Equatable
  {
    contains(key) ? try decode(type, forKey: key) : nil
  }
}
