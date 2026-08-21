import Foundation

/// The camera GlassifAI uses for visual questions. The raw value is persisted
/// in UserDefaults so changing it in Settings applies without a relaunch.
enum CaptureSource: String, CaseIterable {
  case iPhoneCamera = "iphone"
  case glasses = "glasses"

  static let defaultsKey = "captureSource"

  var label: String {
    switch self {
    case .iPhoneCamera: "iPhone"
    case .glasses: "Glasses"
    }
  }
}
