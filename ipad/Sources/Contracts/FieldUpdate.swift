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
