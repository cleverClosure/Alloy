// Author: Timur Isaev

import Foundation

enum VDFValue {
  case string(String)
  case object([String: VDFValue])
}

enum VDFToken {
  case string(String, offset: Int)
  case openBrace(offset: Int)
  case closeBrace(offset: Int)
  case end(offset: Int)

  var offset: Int {
    switch self {
    case .string(_, let offset),
      .openBrace(let offset),
      .closeBrace(let offset),
      .end(let offset):
      offset
    }
  }
}

struct VDFParser {
  let bytes: [UInt8]
  let sourceName: String
  let maximumDepth: Int
  let maximumTokenBytes: Int
  private(set) var offset = 0

  init(
    bytes: [UInt8],
    sourceName: String,
    maximumDepth: Int,
    maximumTokenBytes: Int
  ) {
    self.bytes = bytes
    self.sourceName = sourceName
    self.maximumDepth = maximumDepth
    self.maximumTokenBytes = maximumTokenBytes
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
      offset = 3
    }
  }

  mutating func parseDocument() throws -> [String: VDFValue] {
    try parseEntries(depth: 0, requiresClosingBrace: false)
  }

  private mutating func parseEntries(
    depth: Int,
    requiresClosingBrace: Bool
  ) throws -> [String: VDFValue] {
    var object = [String: VDFValue]()
    while true {
      let token = try nextToken()
      guard let (key, keyOffset) = try entryKey(
        token,
        requiresClosingBrace: requiresClosingBrace
      ) else {
        return object
      }
      let value = try nextValue(depth: depth)
      try insert(
        value,
        forKey: key,
        keyOffset: keyOffset,
        into: &object
      )
    }
  }

  private func entryKey(
    _ token: VDFToken,
    requiresClosingBrace: Bool
  ) throws -> (String, Int)? {
    switch token {
    case .string(let key, let offset):
      return (key, offset)
    case .end:
      guard !requiresClosingBrace else {
        throw SteamMetadataError.truncatedInput(
          sourceName: sourceName,
          offset: token.offset
        )
      }
      return nil
    case .closeBrace:
      guard requiresClosingBrace else {
        throw SteamMetadataError.malformedNesting(
          sourceName: sourceName,
          offset: token.offset
        )
      }
      return nil
    case .openBrace:
      throw SteamMetadataError.malformedNesting(
        sourceName: sourceName,
        offset: token.offset
      )
    }
  }

  private mutating func nextValue(depth: Int) throws -> VDFValue {
    let token = try nextToken()
    switch token {
    case .string(let value, _):
      return .string(value)
    case .openBrace(let braceOffset):
      return try nestedObject(depth: depth, braceOffset: braceOffset)
    case .end:
      throw SteamMetadataError.truncatedInput(
        sourceName: sourceName,
        offset: token.offset
      )
    case .closeBrace:
      throw SteamMetadataError.malformedNesting(
        sourceName: sourceName,
        offset: token.offset
      )
    }
  }

  private mutating func nestedObject(
    depth: Int,
    braceOffset: Int
  ) throws -> VDFValue {
    let nextDepth = depth + 1
    guard nextDepth <= maximumDepth else {
      throw SteamMetadataError.nestingTooDeep(
        sourceName: sourceName,
        offset: braceOffset,
        maximum: maximumDepth
      )
    }
    return .object(
      try parseEntries(
        depth: nextDepth,
        requiresClosingBrace: true
      )
    )
  }

  private func insert(
    _ value: VDFValue,
    forKey key: String,
    keyOffset: Int,
    into object: inout [String: VDFValue]
  ) throws {
    guard object[key] == nil else {
      throw SteamMetadataError.duplicateKey(
        sourceName: sourceName,
        key: key,
        offset: keyOffset
      )
    }
    object[key] = value
  }

  private mutating func nextToken() throws -> VDFToken {
    skipWhitespace()
    guard offset < bytes.count else {
      return .end(offset: offset)
    }

    let tokenOffset = offset
    switch bytes[offset] {
    case 0x7B:
      offset += 1
      return .openBrace(offset: tokenOffset)
    case 0x7D:
      offset += 1
      return .closeBrace(offset: tokenOffset)
    case 0x22:
      return try quotedString(startOffset: tokenOffset)
    default:
      throw SteamMetadataError.malformedNesting(
        sourceName: sourceName,
        offset: tokenOffset
      )
    }
  }

  private mutating func quotedString(startOffset: Int) throws -> VDFToken {
    offset += 1
    var rawLength = 0
    var decoded = [UInt8]()
    decoded.reserveCapacity(min(64, maximumTokenBytes))

    while offset < bytes.count {
      let byte = bytes[offset]
      if byte == 0x22 {
        return try finishString(decoded, startOffset: startOffset)
      }
      try appendContentByte(
        byte,
        rawLength: &rawLength,
        decoded: &decoded,
        startOffset: startOffset
      )
    }
    throw truncatedInput()
  }

  private mutating func finishString(
    _ decoded: [UInt8],
    startOffset: Int
  ) throws -> VDFToken {
    offset += 1
    guard let value = String(bytes: decoded, encoding: .utf8) else {
      throw SteamMetadataError.invalidUTF8(sourceName: sourceName)
    }
    return .string(value, offset: startOffset)
  }

  private mutating func appendContentByte(
    _ byte: UInt8,
    rawLength: inout Int,
    decoded: inout [UInt8],
    startOffset: Int
  ) throws {
    try incrementRawLength(&rawLength, startOffset: startOffset)
    offset += 1
    guard byte == 0x5C else {
      decoded.append(byte)
      return
    }
    let escaped = try consumeEscapedByte(
      rawLength: &rawLength,
      startOffset: startOffset
    )
    appendEscapedByte(escaped, to: &decoded)
  }

  private mutating func consumeEscapedByte(
    rawLength: inout Int,
    startOffset: Int
  ) throws -> UInt8 {
    guard offset < bytes.count else {
      throw truncatedInput()
    }
    try incrementRawLength(&rawLength, startOffset: startOffset)
    let escaped = bytes[offset]
    offset += 1
    return escaped
  }

  private func incrementRawLength(
    _ rawLength: inout Int,
    startOffset: Int
  ) throws {
    rawLength += 1
    guard rawLength <= maximumTokenBytes else {
      throw SteamMetadataError.tokenTooLarge(
        sourceName: sourceName,
        offset: startOffset,
        maximum: maximumTokenBytes
      )
    }
  }

  private func appendEscapedByte(
    _ escaped: UInt8,
    to decoded: inout [UInt8]
  ) {
    switch escaped {
    case 0x22, 0x5C:
      decoded.append(escaped)
    case 0x6E:
      decoded.append(0x0A)
    case 0x72:
      decoded.append(0x0D)
    case 0x74:
      decoded.append(0x09)
    default:
      decoded.append(0x5C)
      decoded.append(escaped)
    }
  }

  private func truncatedInput() -> SteamMetadataError {
    SteamMetadataError.truncatedInput(
      sourceName: sourceName,
      offset: offset
    )
  }

  private mutating func skipWhitespace() {
    while offset < bytes.count {
      switch bytes[offset] {
      case 0x09, 0x0A, 0x0D, 0x20:
        offset += 1
      default:
        return
      }
    }
  }
}
