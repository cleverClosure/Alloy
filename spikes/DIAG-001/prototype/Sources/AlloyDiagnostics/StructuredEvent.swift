// Author: Timur Isaev

import Foundation

public struct EventField: Codable, Equatable, Sendable {
  public let name: String
  public let value: String
  public let dataClass: DataClass

  public init(name: String, value: String, dataClass: DataClass) throws {
    try ModelValidation.identifier(name, field: "fields.name")
    self.name = name
    self.value = value
    self.dataClass = dataClass
  }

  public init(from decoder: any Decoder) throws {
    try ModelValidation.rejectUnknownKeys(decoder, allowed: CodingKeys.self)
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      name: values.decode(String.self, forKey: .name),
      value: values.decode(String.self, forKey: .value),
      dataClass: values.decode(DataClass.self, forKey: .dataClass)
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case name
    case value
    case dataClass = "data_class"
  }
}

public struct StructuredEvent: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1
  public let schemaVersion: Int
  public let eventCode: String
  public let timestampUnixMilliseconds: Int64
  public let correlation: CorrelationID
  public let fields: [EventField]

  public init(
    eventCode: String,
    timestampUnixMilliseconds: Int64,
    correlation: CorrelationID,
    fields: [EventField]
  ) throws {
    try ModelValidation.identifier(eventCode, field: "event_code")
    guard timestampUnixMilliseconds >= 0 else {
      throw DiagnosticModelError.invalidValue(field: "timestamp_unix_milliseconds")
    }
    guard Set(fields.map(\.name)).count == fields.count else {
      throw DiagnosticModelError.invalidValue(field: "fields.duplicate_name")
    }
    self.schemaVersion = Self.currentSchemaVersion
    self.eventCode = eventCode
    self.timestampUnixMilliseconds = timestampUnixMilliseconds
    self.correlation = correlation
    self.fields = fields
  }

  public init(from decoder: any Decoder) throws {
    try ModelValidation.rejectUnknownKeys(decoder, allowed: CodingKeys.self)
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let version = try values.decode(Int.self, forKey: .schemaVersion)
    guard version == Self.currentSchemaVersion else {
      throw DiagnosticModelError.unsupportedSchemaVersion(version)
    }
    try self.init(
      eventCode: values.decode(String.self, forKey: .eventCode),
      timestampUnixMilliseconds: values.decode(Int64.self, forKey: .timestampUnixMilliseconds),
      correlation: values.decode(CorrelationID.self, forKey: .correlation),
      fields: values.decode([EventField].self, forKey: .fields)
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case eventCode = "event_code"
    case timestampUnixMilliseconds = "timestamp_unix_milliseconds"
    case correlation
    case fields
  }
}
