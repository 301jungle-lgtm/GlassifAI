import AVFoundation
import SwiftUI
import UIKit

struct GlassifAIExperienceView: View {
  let captureSource: CaptureSource
  let glassesImage: UIImage?
  let glassesPlaceholder: (title: String, caption: String)
  @ObservedObject var voice: GlassifAIRealtimeSession
  @ObservedObject var camera: GlassifAICamera
  @State private var showSettings = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var caption: (role: String, text: String)? {
    if !voice.assistantCaption.isEmpty { return ("GlassifAI", voice.assistantCaption) }
    if !voice.userTranscript.isEmpty { return ("You", voice.userTranscript) }
    return nil
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      cameraLayer
      LinearGradient(
        colors: [.black.opacity(0.52), .clear, .black.opacity(0.72)],
        startPoint: .top,
        endPoint: .bottom)
        .ignoresSafeArea()
        .allowsHitTesting(false)

      VStack(spacing: 0) {
        topBar
        Spacer(minLength: 24)
        conversationControls
      }
      .padding(.horizontal, 18)
      .padding(.bottom, 12)
    }
    .preferredColorScheme(.dark)
    .sheet(isPresented: $showSettings) {
      SettingsView()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    .sensoryFeedback(trigger: voice.state) { _, state in
      switch state {
      case .listening: .success
      case .failed: .error
      default: nil
      }
    }
    .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
  }

  @ViewBuilder
  private var cameraLayer: some View {
    if captureSource == .iPhoneCamera {
      GlassifAICameraPreview(session: camera.captureSession)
        .ignoresSafeArea()
    } else if let glassesImage {
      Image(uiImage: glassesImage)
        .resizable()
        .scaledToFill()
        .ignoresSafeArea()
    } else {
      Color.black
        .ignoresSafeArea()
        .overlay {
          VStack(spacing: 18) {
            Image(systemName: "eyeglasses")
              .font(.system(size: 42, weight: .light))
            VStack(spacing: 6) {
              Text(glassesPlaceholder.title)
                .font(.title3.bold())
              Text(glassesPlaceholder.caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
          }
          .padding(.horizontal, 40)
        }
    }
  }

  private var topBar: some View {
    HStack(spacing: 10) {
      Text("GlassifAI")
        .font(.headline)
      Spacer()
      Label(
        captureSource == .glasses ? "Glasses" : "iPhone",
        systemImage: captureSource == .glasses ? "eyeglasses" : "iphone")
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(.thinMaterial, in: Capsule())
        .accessibilityLabel(captureSource == .glasses ? "Camera source: glasses" : "Camera source: iPhone")
      Button { showSettings = true } label: {
        Image(systemName: "gearshape")
          .frame(width: 44, height: 44)
          .background(.thinMaterial, in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Open GlassifAI settings")
    }
    .padding(.top, 8)
  }

  private var conversationControls: some View {
    VStack(spacing: 14) {
      if let caption {
        VStack(alignment: .leading, spacing: 6) {
          Text(caption.role)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(caption.text)
            .font(.body.weight(.medium))
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(.opacity)
      } else if voice.state == .disconnected {
        Text("Ask anything about what you see")
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.72))
      }

      HStack {
        statusView
          .frame(maxWidth: .infinity, alignment: .leading)

        callButton

        Group {
          if voice.state == .speaking {
            Button { voice.stopSpeaking() } label: {
              Image(systemName: "hand.raised.fill")
                .frame(width: 48, height: 48)
                .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Interrupt response")
            .accessibilityHint("Stops the current response and keeps listening")
          } else {
            Color.clear.frame(width: 48, height: 48)
          }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: voice.state)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: caption?.text)
  }

  private var statusView: some View {
    HStack(spacing: 7) {
      stateGlyph
      Text(voice.state.shortLabel)
        .font(.footnote.weight(.medium))
    }
    .foregroundStyle(.white.opacity(0.86))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("GlassifAI status: \(voice.state.label)")
  }

  @ViewBuilder
  private var stateGlyph: some View {
    switch voice.state {
    case .connecting:
      ProgressView().controlSize(.small).tint(.white)
    case .listening:
      Image(systemName: "ear.fill")
    case .thinking:
      Image(systemName: "ellipsis")
    case .speaking:
      Image(systemName: "waveform")
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
    case .disconnected:
      Image(systemName: "circle.fill").font(.system(size: 7))
    }
  }

  private var callButton: some View {
    Button {
      Task {
        if voice.isActive { await voice.stop() }
        else { await voice.start() }
      }
    } label: {
      ZStack {
        Circle()
          .fill(voice.isActive ? Color.red : GlassifAITheme.accent)
          .frame(width: 74, height: 74)
          .shadow(color: .black.opacity(0.24), radius: 12, y: 6)
        if voice.state == .connecting {
          ProgressView().tint(.white)
        } else {
          Image(systemName: voice.isActive ? "phone.down.fill" : "waveform")
            .font(.system(size: 25, weight: .semibold))
            .foregroundStyle(.white)
        }
      }
      .frame(width: 78, height: 78)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(voice.state == .connecting)
    .accessibilityLabel(voice.isActive ? "End conversation" : "Start conversation")
    .accessibilityHint(voice.isActive ? "Ends ChatGPT voice" : "Starts a live ChatGPT voice conversation")
  }
}

private extension GlassifAIRealtimeSession.State {
  var label: String {
    switch self {
    case .disconnected: "Ready"
    case .connecting: "Connecting securely"
    case .listening: "Listening"
    case .thinking: "Thinking"
    case .speaking: "Speaking"
    case .failed(let message): message
    }
  }

  var shortLabel: String {
    switch self {
    case .disconnected: "Ready"
    case .connecting: "Connecting"
    case .listening: "Listening"
    case .thinking: "Thinking"
    case .speaking: "Speaking"
    case .failed: "Error"
    }
  }
}
