/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// GlassifAIApp.swift
//
// GlassifAI opens with a camera-first voice experience. Meta glasses are an
// optional visual source selected in Settings, and their connection flow only
// appears when needed.
//

import Foundation
import MWDATCore
import SwiftUI


@main
struct GlassifAIApp: App {
  /// nil when the Wearables SDK could not start (no hardware, e.g. the
  /// simulator). Accessing `Wearables.shared` after a failed `configure()`
  /// traps, so nothing glasses-related may be built in that case. The camera
  /// experience does not depend on it.
  private let wearables: WearablesInterface?

  init() {
    var available: WearablesInterface?
    do {
      try Wearables.configure()
      available = Wearables.shared
    } catch {
      NSLog("[GlassifAI] Wearables SDK unavailable: \(error)")
    }
    self.wearables = available
  }

  var body: some Scene {
    WindowGroup {
      VisionRootView(wearables: wearables)
        .preferredColorScheme(.dark)
    }
  }
}

private enum GlassifAIPreviewMode {
  static var showsOnboarding: Bool {
    #if DEBUG
    ProcessInfo.processInfo.arguments.contains("--preview-onboarding")
    #else
    false
    #endif
  }
}

/// Authentication and all AI traffic are device-local; Meta remains only the
/// optional glasses hardware bridge.
struct VisionRootView: View {
  let wearables: WearablesInterface?
  @State private var auth = ChatGPTAuthSession.shared

  var body: some View {
    Group {
      if GlassifAIPreviewMode.showsOnboarding || !auth.isAuthenticated {
        AccessCodeView()
      } else if let wearables {
        GlassesCapableRootView(wearables: wearables)
      } else {
        StreamSessionView(wearables: nil, wearablesVM: nil)
      }
    }
    .task {
      if case .loading = auth.status { await auth.restore() }
    }
  }
}

struct AccessCodeView: View {
  var body: some View {
    ZStack {
      GlassifAIBackdrop()
      ScrollView {
        VStack(spacing: 36) {
          Spacer(minLength: 72)
          AuthenticationHeader()
          ChatGPTLoginView()
          Label("Credentials stay on this iPhone", systemImage: "lock.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
          Spacer(minLength: 40)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.hidden)
    }
  }
}

private struct AuthenticationHeader: View {
  var body: some View {
    VStack(spacing: 18) {
      GlassifAIMark(size: 116)
      VStack(spacing: 8) {
        Text("GlassifAI")
          .font(.largeTitle.bold())
        Text("See it. Ask it. Understand it.")
          .font(.headline)
          .foregroundStyle(.secondary)
      }
      Text("Live ChatGPT voice and vision for your iPhone and Meta glasses.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

private struct ChatGPTLoginView: View {
  @Environment(\.openURL) private var openURL
  @State private var auth = ChatGPTAuthSession.shared
  @State private var showConsent = false
  private var displayStatus: ChatGPTAuthStatus {
    GlassifAIPreviewMode.showsOnboarding ? .unauthenticated : auth.status
  }

  var body: some View {
    VStack(spacing: 16) {
      switch displayStatus {
      case .loading, .connecting:
        ProgressView("Connecting securely…")
          .frame(maxWidth: .infinity, minHeight: 72)
      case .pending(let login):
        VStack(spacing: 18) {
          Text("Finish connecting")
            .font(.headline)
          Text("Enter this one-time code on OpenAI’s verification page.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Text(verbatim: login.userCode)
            .font(.system(.title2, design: .monospaced).bold())
            .tracking(3)
            .textSelection(.enabled)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
          HStack {
            Button {
              UIPasteboard.general.string = login.userCode
            } label: {
              Label("Copy", systemImage: "doc.on.doc")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button {
              openURL(login.verificationUrl)
            } label: {
              Label("Open OpenAI", systemImage: "arrow.up.right")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
          }
          .controlSize(.large)
        }
      case .authenticated(let user):
        Label(user.email ?? user.name ?? "ChatGPT connected", systemImage: "checkmark.circle.fill")
          .font(.headline)
          .foregroundStyle(.green)
          .frame(maxWidth: .infinity, minHeight: 64)
      case .error(let message):
        VStack(spacing: 14) {
          Label("Couldn’t connect", systemImage: "exclamationmark.triangle.fill")
            .font(.headline)
            .foregroundStyle(.red)
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Button("Try Again") { showConsent = true }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
      case .unauthenticated:
        Button { showConsent = true } label: {
          HStack {
            Image(systemName: "bubble.left.and.text.bubble.right")
            Text("Continue with ChatGPT")
            Spacer()
            Image(systemName: "chevron.right")
              .font(.caption.bold())
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .controlSize(.large)
      }
    }
    .padding(20)
    .glassifAIPanel()
    .sheet(isPresented: $showConsent) {
      ChatGPTConsentView {
        showConsent = false
        Task {
          if let login = try? await auth.startLogin() {
            openURL(login.verificationUrl)
          }
        }
      }
    }
  }
}

struct ChatGPTConsentView: View {
  let onContinue: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 24) {
        GlassifAIMark(size: 76)
          .frame(maxWidth: .infinity)
        VStack(alignment: .leading, spacing: 8) {
          Text("Connect ChatGPT")
            .font(.title2.bold())
          Text("GlassifAI uses your ChatGPT plan for live voice and visual requests.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: 18) {
          consentRow("Credentials are protected by this iPhone’s Keychain", icon: "key.fill")
          consentRow("Camera frames are sent only while you use the app", icon: "camera.fill")
          consentRow("Disconnecting removes the local session", icon: "trash")
        }
        Spacer(minLength: 12)
        Button("Continue", action: onContinue)
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.roundedRectangle(radius: 14))
          .controlSize(.large)
          .frame(maxWidth: .infinity)
        Button("Cancel", role: .cancel) { dismiss() }
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .padding(24)
      .navigationBarTitleDisplayMode(.inline)
    }
    .presentationDetents([.medium, .large])
  }

  private func consentRow(_ text: String, icon: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: icon)
        .foregroundStyle(.tint)
        .frame(width: 24)
      Text(text)
        .font(.subheadline)
    }
  }
}


/// The full app when the glasses SDK is available. Registration callbacks are
/// handled alongside the same camera-first experience used in iPhone mode.
private struct GlassesCapableRootView: View {
  let wearables: WearablesInterface
  @StateObject private var viewModel: WearablesViewModel

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self._viewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
  }

  var body: some View {
    StreamSessionView(wearables: wearables, wearablesVM: viewModel)
      .alert("Glasses unavailable", isPresented: $viewModel.showError) {
        Button("OK") { viewModel.dismissError() }
      } message: {
        Text(viewModel.errorMessage)
      }

    RegistrationView(viewModel: viewModel)
  }
}
