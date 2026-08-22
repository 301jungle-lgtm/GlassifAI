import Foundation
import MWDATCore

enum GlassesGestureAction: Equatable {
  case toggleMicrophoneMute
  case endCall
}

struct GlassesGestureInterpreter {
  private(set) var previousState: SessionState?
  private var becameActive = false

  mutating func receive(_ state: SessionState) -> GlassesGestureAction? {
    let previous = previousState
    previousState = state

    switch state {
    case .running:
      becameActive = true
      return previous == .paused ? .toggleMicrophoneMute : nil
    case .paused:
      return previous == .running ? .toggleMicrophoneMute : nil
    case .stopped:
      guard becameActive else { return nil }
      becameActive = false
      return .endCall
    case .waitingForDevice, .unknown:
      return nil
    }
  }

  mutating func reset() {
    previousState = nil
    becameActive = false
  }
}

/// Runs a capability-free DAT session alongside an active voice call and turns
/// Meta's fixed temple gestures into call controls.
///
/// DAT exposes session-state transitions rather than raw gesture events:
/// - running → paused or paused → running: temple tap, toggle microphone mute
/// - any active state → stopped: long press, doff, fold, or link loss, end call
///
/// `stopped` does not include a reason, so those stop cases cannot be
/// distinguished. Programmatic teardown is suppressed explicitly.
@MainActor
final class GlassesGestureSession {
  private let wearables: WearablesInterface
  private var session: DeviceStateSession?
  private var listenerToken: (any AnyListenerToken)?
  private var activeDeviceId: DeviceIdentifier?
  private var interpreter = GlassesGestureInterpreter()
  private var isStopping = false
  private var onTap: (() -> Void)?
  private var onStop: (() -> Void)?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
  }

  func start(
    deviceId: DeviceIdentifier,
    onTap: @escaping () -> Void,
    onStop: @escaping () -> Void
  ) async {
    if activeDeviceId == deviceId, session != nil {
      self.onTap = onTap
      self.onStop = onStop
      return
    }
    await stop()
    activeDeviceId = deviceId

    self.onTap = onTap
    self.onStop = onStop
    interpreter.reset()
    isStopping = false

    let selector = SpecificDeviceSelector(device: deviceId)
    let session = DeviceStateSession(deviceSelector: selector)
    self.session = session
    listenerToken = await wearables.addDeviceSessionStateListener(forDeviceId: deviceId) {
      [weak self] state in
      Task { @MainActor in
        self?.receive(state)
      }
    }

    do {
      try await session.start()
      NSLog("[GlassifAI] glasses gesture session started")
    } catch {
      NSLog("[GlassifAI] glasses gesture session unavailable: %@", error.localizedDescription)
      await stop()
    }
  }

  func stop() async {
    isStopping = true
    let token = listenerToken
    listenerToken = nil
    await token?.cancel()

    if let session {
      try? await session.stop()
    }
    self.session = nil
    activeDeviceId = nil
    interpreter.reset()
    onTap = nil
    onStop = nil
    isStopping = false
  }

  private func receive(_ state: SessionState) {
    let previous = interpreter.previousState
    NSLog(
      "[GlassifAI] glasses gesture state: %@ -> %@",
      previous?.description ?? "none",
      state.description)

    guard !isStopping else { return }
    switch interpreter.receive(state) {
    case .toggleMicrophoneMute:
      onTap?()
    case .endCall:
      onStop?()
    case nil:
      break
    }
  }
}
