// Author: Timur Isaev

import Foundation

/// Classification describes content; it does not grant consent or certify successful redaction.
public enum DataClass: String, Codable, CaseIterable, Sendable {
  case componentVersions = "component_versions"
  case metadataVerification = "metadata_verification"
  case errorCode = "error_code"
  case hostCapabilities = "host_capabilities"
  case gameProfileIdentifiers = "game_profile_identifiers"
  case runtimeOutcome = "runtime_outcome"
  case pseudonymousClientIdentifier = "pseudonymous_client_identifier"
  case saveGameContent = "save_game_content"
  case chatVoiceContent = "chat_voice_content"
  case gameplayVideo = "gameplay_video"
  case screenshots
  case homePaths = "home_paths"
  case credentials
  case moduleProcessFileInventory = "module_process_file_inventory"
  case usernames
  case tokensCookies = "tokens_cookies"
  case sensitiveURLs = "sensitive_urls"

  public var references: [DataCategoryReference] {
    switch self {
    case .componentVersions:
      [.init(section: "17.1", category: "product/component versions")]
    case .metadataVerification:
      [.init(section: "17.1", category: "signed metadata result")]
    case .errorCode:
      [.init(section: "17.1", category: "stable error code")]
    case .hostCapabilities:
      [.init(section: "17.1", category: "coarse host capability class")]
    case .gameProfileIdentifiers:
      [.init(section: "17.1", category: "game/profile identifiers")]
    case .runtimeOutcome:
      [.init(section: "17.1", category: "severe crash/device-loss/rollback outcome")]
    case .pseudonymousClientIdentifier:
      [.init(section: "17.1", category: "pseudonymous rotating client identifier")]
    case .saveGameContent:
      [.init(section: "17.1", category: "save content"), .init(section: "18", category: "save/game content")]
    case .chatVoiceContent:
      [.init(section: "17.1", category: "chat/voice"), .init(section: "18", category: "chat")]
    case .gameplayVideo:
      [.init(section: "17.1", category: "gameplay video")]
    case .screenshots:
      [.init(section: "17.1", category: "screenshots")]
    case .homePaths:
      [.init(section: "17.1", category: "full home paths"), .init(section: "18", category: "home prefixes")]
    case .credentials:
      [.init(section: "17.1", category: "credentials")]
    case .moduleProcessFileInventory:
      [.init(section: "17.1", category: "unrelated process/file inventory")]
    case .usernames:
      [.init(section: "18", category: "usernames")]
    case .tokensCookies:
      [.init(section: "18", category: "tokens"), .init(section: "18", category: "cookies")]
    case .sensitiveURLs:
      [.init(section: "18", category: "URLs/query strings where sensitive")]
    }
  }
}

public struct DataCategoryReference: Hashable, Sendable {
  public static let document = "docs/docs/09_SECURITY_PRIVACY_THREAT_MODEL.md"
  public let section: String
  public let category: String

  public init(section: String, category: String) {
    self.section = section
    self.category = category
  }
}

/// Mechanism names from security doc §17.2. The prototype chooses no shipped default.
public enum ConsentLevel: String, Codable, CaseIterable, Sendable {
  case off
  case essential
  case diagnostic
  case lab
}
