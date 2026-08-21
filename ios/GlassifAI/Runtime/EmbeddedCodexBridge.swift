import Foundation
import GlassifAICodex

struct EmbeddedCodexResult: Decodable {
  let ok: Bool
  let sdp: String?
  let callId: String?
  let error: String?

  enum CodingKeys: String, CodingKey {
    case ok
    case sdp
    case callId = "call_id"
    case error
  }
}

enum EmbeddedCodexBridge {
  static func startRealtime(
    tokens: ChatGPTAuthTokens,
    sdp: String
  ) async throws -> EmbeddedCodexResult {
    guard let accountId = tokens.accountId else { throw EmbeddedCodexError.missingAccount }
    return try await Task.detached(priority: .userInitiated) {
      let pointer = tokens.accessToken.withCString { accessToken in
        accountId.withCString { account in
          sdp.withCString { offer in
            glassifai_codex_realtime_start(accessToken, account, offer)
          }
        }
      }
      guard let pointer else { throw EmbeddedCodexError.bridgeFailed }
      defer { glassifai_codex_string_free(pointer) }
      let data = Data(String(cString: pointer).utf8)
      return try JSONDecoder().decode(EmbeddedCodexResult.self, from: data)
    }.value
  }

  static func completeDelegation(handoffId: String, text: String) -> Bool {
    handoffId.withCString { handoff in
      text.withCString { content in
        glassifai_codex_delegation_complete(handoff, content)
      }
    }
  }

  static func nextSidebandEvent() -> [String: Any]? {
    guard let pointer = glassifai_codex_next_sideband_event() else { return nil }
    defer { glassifai_codex_string_free(pointer) }
    let data = Data(String(cString: pointer).utf8)
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  static func sidebandStatus() -> String {
    guard let pointer = glassifai_codex_sideband_status() else { return "status unavailable" }
    defer { glassifai_codex_string_free(pointer) }
    return String(cString: pointer)
  }

  static func closeRealtime() {
    glassifai_codex_realtime_close()
  }
}

private enum EmbeddedCodexError: LocalizedError {
  case missingAccount
  case bridgeFailed

  var errorDescription: String? {
    switch self {
    case .missingAccount: "The ChatGPT account identifier is missing."
    case .bridgeFailed: "The embedded Codex bridge could not start."
    }
  }
}
