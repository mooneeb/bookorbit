import CryptoKit
import Foundation
import XCTest
import zlib

enum CatalogPluginArtifactSupport {
  static func validate(_ data: Data, server: String, username: String, password: String) throws
    -> [String: Any]
  {
    guard data.count > 22, data.count <= 16 * 1024 * 1024 else { throw InvalidZip.bounds }
    let bytes = [UInt8](data)
    let lower = max(0, bytes.count - 65_557)
    let end = try XCTUnwrap(
      (lower...(bytes.count - 22)).reversed().first {
        Array(bytes[$0..<($0 + 4)]) == [0x50, 0x4b, 0x05, 0x06]
      })
    func number(_ offset: Int, _ length: Int) throws -> Int {
      guard offset >= 0, offset + length <= bytes.count else { throw InvalidZip.bounds }
      return (0..<length).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
    }
    XCTAssertEqual(try number(end + 4, 2), 0)
    XCTAssertEqual(try number(end + 6, 2), 0)
    let count = try number(end + 10, 2)
    XCTAssertEqual(try number(end + 8, 2), count)
    guard (1...512).contains(count) else { throw InvalidZip.bounds }
    let directorySize = try number(end + 12, 4)
    var cursor = try number(end + 16, 4)
    let directoryStart = cursor
    let directoryEnd = cursor + directorySize
    guard directoryEnd == end else { throw InvalidZip.bounds }
    var entries = Set<String>()
    var provision: String?
    for _ in 0..<count {
      guard try number(cursor, 4) == 0x0201_4b50 else { throw InvalidZip.signature }
      let flags = try number(cursor + 8, 2)
      let method = try number(cursor + 10, 2)
      let crc = try number(cursor + 16, 4)
      let compressed = try number(cursor + 20, 4)
      let size = try number(cursor + 24, 4)
      let nameLength = try number(cursor + 28, 2)
      let extraLength = try number(cursor + 30, 2)
      let commentLength = try number(cursor + 32, 2)
      let local = try number(cursor + 42, 4)
      guard nameLength > 0, nameLength <= 1024, cursor + 46 + nameLength <= directoryEnd,
        compressed <= 2 * 1024 * 1024, size <= 2 * 1024 * 1024, flags & 1 == 0
      else { throw InvalidZip.bounds }
      let name = try XCTUnwrap(
        String(bytes: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8))
      guard name.hasPrefix("bookorbit.koplugin/"), !name.split(separator: "/").contains(".."),
        entries.insert(name).inserted
      else { throw InvalidZip.signature }
      if name == "bookorbit.koplugin/bookorbit_provision.lua" {
        guard try number(local, 4) == 0x0403_4b50 else { throw InvalidZip.signature }
        XCTAssertEqual(try number(local + 8, 2), method)
        let payload = local + 30 + (try number(local + 26, 2)) + (try number(local + 28, 2))
        guard payload >= 0, payload + compressed <= directoryStart else { throw InvalidZip.bounds }
        let encoded = Data(bytes[payload..<(payload + compressed)])
        let decoded: Data
        if method == 0 {
          decoded = encoded
        } else if method == 8 {
          decoded = try inflateRaw(encoded, size: size)
        } else {
          throw InvalidZip.signature
        }
        XCTAssertEqual(decoded.count, size)
        let actualCRC = decoded.withUnsafeBytes {
          crc32(crc32(0, nil, 0), $0.bindMemory(to: Bytef.self).baseAddress, uInt(decoded.count))
        }
        XCTAssertEqual(actualCRC, uLong(crc))
        provision = try XCTUnwrap(String(data: decoded, encoding: .utf8))
      }
      cursor += 46 + nameLength + extraLength + commentLength
    }
    XCTAssertEqual(cursor, directoryEnd)
    XCTAssertTrue(entries.contains("bookorbit.koplugin/main.lua"))
    let settings = try XCTUnwrap(provision)
    let origin = try XCTUnwrap(URLComponents(string: server))
    let serverOrigin =
      "\(try XCTUnwrap(origin.scheme))://\(try XCTUnwrap(origin.host))"
      + (origin.port.map { ":\($0)" } ?? "")
    XCTAssertTrue(settings.contains("server_url = \"\(serverOrigin)\""))
    XCTAssertTrue(settings.contains("username = \"\(username)\""))
    let key = Insecure.MD5.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }
      .joined()
    XCTAssertTrue(settings.contains("userkey = \"\(key)\""))
    XCTAssertFalse(settings.contains(password))
    return [
      "bytes": data.count,
      "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      "entries": entries.sorted(), "provisionValidated": true,
    ]
  }

  private static func inflateRaw(_ data: Data, size: Int) throws -> Data {
    guard size > 0, size <= 2 * 1024 * 1024 else { throw InvalidZip.bounds }
    var output = Data(count: size)
    let result = data.withUnsafeBytes { source in
      output.withUnsafeMutableBytes { destination -> Int32 in
        var stream = z_stream()
        stream.next_in = UnsafeMutablePointer(
          mutating: source.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(data.count)
        stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
        stream.avail_out = uInt(size)
        let initialized = inflateInit2_(
          &stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { return initialized }
        defer { inflateEnd(&stream) }
        let result = inflate(&stream, Z_FINISH)
        guard stream.total_out == size, stream.avail_in == 0 else { return Z_DATA_ERROR }
        return result
      }
    }
    guard result == Z_STREAM_END else { throw InvalidZip.signature }
    return output
  }

  private enum InvalidZip: Error { case bounds, signature }
}
