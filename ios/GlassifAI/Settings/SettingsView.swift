import SwiftUI

private struct ChatGPTAccountSection: View {
  let status: ChatGPTAuthStatus
  let models: [String]
  let onConnect: () -> Void
  let onOpenVerification: (URL) -> Void
  let onDisconnect: () -> Void

  var body: some View {
    switch status {
    case .loading, .connecting:
      HStack {
        Text("Status")
        Spacer()
        ProgressView()
      }
    case .unauthenticated:
      Button("Connect ChatGPT", action: onConnect)
    case .pending(let login):
      VStack(alignment: .leading, spacing: 10) {
        Text("Waiting for OpenAI verification")
          .font(.subheadline)
        Text(verbatim: login.userCode)
          .font(.system(.title3, design: .monospaced, weight: .semibold))
          .textSelection(.enabled)
        HStack {
          Button("Copy Code") { UIPasteboard.general.string = login.userCode }
          Button("Open OpenAI") { onOpenVerification(login.verificationUrl) }
        }
      }
    case .authenticated(let user):
      VStack(alignment: .leading, spacing: 8) {
        Label(user.email ?? user.name ?? "Connected", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        if let plan = user.plan {
          Text("Plan: \(plan)")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if !models.isEmpty {
          Text("Available models: \(models.count)")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        Button("Disconnect ChatGPT", role: .destructive, action: onDisconnect)
      }
    case .error(let message):
      VStack(alignment: .leading, spacing: 8) {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.red)
        Button("Try Again", action: onConnect)
      }
    }
  }
}

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var chatGPT = ChatGPTAuthSession.shared
  @State private var showChatGPTConsent = false
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue

  var body: some View {
    NavigationStack {
      Form {
        Section(
          header: Text("Vision source"),
          footer: Text(captureSourceRaw == CaptureSource.glasses.rawValue
            ? "Uses the camera in your connected Meta glasses."
            : "Uses this iPhone’s back camera.")) {
          Picker("Source", selection: $captureSourceRaw) {
            ForEach(CaptureSource.allCases, id: \.rawValue) { source in
              Text(source.label).tag(source.rawValue)
            }
          }
          .pickerStyle(.segmented)
        }

        Section(
          header: Text("ChatGPT account"),
          footer: Text("Credentials stay in this iPhone’s protected Keychain and are sent only to OpenAI.")) {
          ChatGPTAccountSection(
            status: chatGPT.status,
            models: chatGPT.availableModels,
            onConnect: { showChatGPTConsent = true },
            onOpenVerification: { openURL($0) },
            onDisconnect: { Task { await chatGPT.logout() } })
        }

        Section(
          header: Text("About"),
          footer: Text("Voice and vision run directly between this iPhone and ChatGPT. No Mac, gateway, or API key.")) {
          Label("On-device Codex bridge", systemImage: "iphone")
          Label("Live ChatGPT voice", systemImage: "waveform")
          Label("Memory-only camera frames", systemImage: "lock.shield")
          if let model = chatGPT.availableModels.first {
            LabeledContent("Vision model", value: model)
          }
        }
      }
      .navigationTitle("GlassifAI")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .fontWeight(.semibold)
        }
      }
      .sheet(isPresented: $showChatGPTConsent) {
        ChatGPTConsentView {
          showChatGPTConsent = false
          Task {
            if let login = try? await chatGPT.startLogin() {
              openURL(login.verificationUrl)
            }
          }
        }
      }
      .task {
        if case .loading = chatGPT.status { await chatGPT.restore() }
      }
    }
    .tint(GlassifAITheme.accent)
  }
}
