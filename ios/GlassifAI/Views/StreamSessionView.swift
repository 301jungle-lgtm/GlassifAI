import MWDATCore
import SwiftUI
import UIKit

struct StreamSessionView: View {
  let wearables: WearablesInterface?
  private let wearablesViewModel: WearablesViewModel?
  @StateObject private var viewModel: StreamSessionViewModel
  @StateObject private var voice = GlassifAIRealtimeSession()
  @StateObject private var camera = GlassifAICamera()
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @State private var glassesAutoStarted = false
  @State private var glassesRegistered = false
  @State private var gestureSession: GlassesGestureSession?
  @Environment(\.scenePhase) private var scenePhase

  private var captureSource: CaptureSource {
    CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera
  }

  private var glassesPlaceholder: (title: String, caption: String) {
    switch viewModel.glassesIssue {
    case .sdkUnavailable:
      ("Glasses unavailable", "Use the iPhone camera or try again on a supported device.")
    case .permissionNeeded:
      ("Permission needed", "Allow camera access for GlassifAI in the Meta AI app.")
    case .hingesClosed:
      ("Glasses folded", "Open the hinges to begin seeing through your glasses.")
    case .reconnecting:
      ("Reconnecting", "GlassifAI will show your view as soon as the glasses wake up.")
    case nil:
      ("Waiting for glasses", "Open your glasses and keep them near your iPhone.")
    }
  }

  init(wearables: WearablesInterface?, wearablesVM: WearablesViewModel?) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    Group {
      if captureSource == .glasses,
         let wearablesViewModel,
         wearablesViewModel.registrationState != .registered,
         !glassesRegistered,
         !wearablesViewModel.hasMockDevice {
        HomeScreenView(viewModel: wearablesViewModel) {
          glassesRegistered = true
          glassesAutoStarted = false
          Task { await activateCaptureSource() }
        }
      } else {
        GlassifAIExperienceView(
          captureSource: captureSource,
          glassesImage: viewModel.currentVideoFrame,
          glassesPlaceholder: glassesPlaceholder,
          voice: voice,
          camera: camera)
      }
    }
    .task {
      camera.onVisionJPEG = { jpeg in voice.submitVisionJPEG(jpeg) }
      viewModel.onVisionJPEG = { jpeg in voice.submitVisionJPEG(jpeg) }
      if gestureSession == nil, let wearables {
        gestureSession = GlassesGestureSession(wearables: wearables)
      }
      glassesRegistered =
        wearablesViewModel?.registrationState == .registered ||
        wearablesViewModel?.hasMockDevice == true
      await activateCaptureSource()
      await updateGestureSession()
    }
    .onChange(of: captureSourceRaw) { _, _ in
      glassesAutoStarted = false
      Task {
        await gestureSession?.stop()
        await voice.stop()
        await activateCaptureSource()
      }
    }
    .onChange(of: voice.state) { _, _ in
      Task { await updateGestureSession() }
    }
    .onChange(of: wearablesViewModel?.devices.first) { _, _ in
      Task { await updateGestureSession() }
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active, captureSource == .glasses else { return }
      glassesAutoStarted = false
      Task { await activateCaptureSource() }
    }
    .onDisappear {
      Task {
        await gestureSession?.stop()
        await voice.stop()
        await camera.stop()
        if viewModel.isStreaming { await viewModel.stopSession() }
      }
    }
    .alert("Camera unavailable", isPresented: $viewModel.showError) {
      Button("OK") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
  }

  private func updateGestureSession() async {
    guard captureSource == .glasses,
          voice.isActive,
          let gestureSession,
          let deviceId = wearablesViewModel?.devices.first ?? wearables?.devices.first else {
      await gestureSession?.stop()
      return
    }

    await gestureSession.start(
      deviceId: deviceId,
      onTap: {
        voice.toggleMicrophoneMuted()
        NSLog(
          "[GlassifAI] glasses temple tap: microphone %@",
          voice.isMicrophoneMuted ? "muted" : "live")
      },
      onStop: {
        Task { @MainActor in
          if voice.isActive {
            await voice.stop()
          }
        }
      })
  }

  private func activateCaptureSource() async {
    if captureSource == .iPhoneCamera {
      glassesAutoStarted = false
      if viewModel.isStreaming { await viewModel.stopSession() }
      await camera.start()
      return
    }

    await camera.stop()
    guard let wearablesViewModel,
          wearablesViewModel.registrationState == .registered ||
            glassesRegistered ||
            wearablesViewModel.hasMockDevice else { return }
    guard !glassesAutoStarted else { return }
    glassesAutoStarted = true
    for _ in 0..<20 {
      await viewModel.handleStartStreaming()
      if viewModel.isStreaming || captureSource != .glasses { break }
      try? await Task.sleep(nanoseconds: 3_000_000_000)
    }
    if !viewModel.isStreaming { glassesAutoStarted = false }
  }
}
