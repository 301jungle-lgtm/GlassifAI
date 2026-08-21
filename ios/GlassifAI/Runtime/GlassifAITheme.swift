import SwiftUI

enum GlassifAITheme {
  static let accent = Color(red: 0.12, green: 0.48, blue: 1)
  static let markGradient = LinearGradient(
    colors: [Color(red: 0.25, green: 0.72, blue: 1), Color(red: 0.45, green: 0.38, blue: 0.95)],
    startPoint: .leading,
    endPoint: .trailing)
}

struct GlassifAIBackdrop: View {
  var body: some View {
    ZStack {
      Color(uiColor: .systemBackground)
      LinearGradient(
        colors: [GlassifAITheme.accent.opacity(0.08), .clear],
        startPoint: .top,
        endPoint: .center)
    }
    .ignoresSafeArea()
  }
}

struct GlassifAIMark: View {
  let size: CGFloat

  var body: some View {
    ZStack {
      HStack(spacing: size * 0.09) {
        lens
        lens
      }
      Capsule()
        .fill(GlassifAITheme.markGradient)
        .frame(width: size * 0.19, height: size * 0.05)
    }
    .frame(width: size, height: size * 0.52)
    .accessibilityHidden(true)
  }

  private var lens: some View {
    RoundedRectangle(cornerRadius: size * 0.13, style: .continuous)
      .fill(.secondary.opacity(0.06))
      .frame(width: size * 0.405, height: size * 0.29)
      .overlay {
        RoundedRectangle(cornerRadius: size * 0.13, style: .continuous)
          .stroke(GlassifAITheme.markGradient, lineWidth: max(3, size * 0.034))
      }
      .overlay {
        Circle()
          .fill(.primary)
          .frame(width: size * 0.035)
      }
  }
}

struct GlassifAIPanelModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(.primary.opacity(0.08), lineWidth: 0.5)
      }
  }
}

extension View {
  func glassifAIPanel() -> some View {
    modifier(GlassifAIPanelModifier())
  }
}
