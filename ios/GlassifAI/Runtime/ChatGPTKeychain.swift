import Foundation
import Security

struct ChatGPTAuthTokens: Codable, Equatable {
  let accessToken: String
  let refreshToken: String?
  let idToken: String?
  let accountId: String?
  let expiresAt: Double?
}

enum ChatGPTKeychain {
  private static let service = "ai.glassifai.chatgpt.oauth"
  private static let account = "primary"

  static func load() throws -> ChatGPTAuthTokens? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw KeychainError.status(status)
    }
    return try JSONDecoder().decode(ChatGPTAuthTokens.self, from: data)
  }

  static func save(_ tokens: ChatGPTAuthTokens) throws {
    let data = try JSONEncoder().encode(tokens)
    let key: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let update = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw KeychainError.status(update) }
    var add = key
    attributes.forEach { add[$0.key] = $0.value }
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError.status(status) }
  }

  static func delete() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.status(status)
    }
  }
}


private enum KeychainError: LocalizedError {
  case status(OSStatus)

  var errorDescription: String? {
    switch self {
    case .status(let status):
      return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
    }
  }
}
