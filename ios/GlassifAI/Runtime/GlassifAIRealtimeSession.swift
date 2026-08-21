import AVFoundation
import Combine
import Foundation
import LiveKitWebRTC

@MainActor
final class GlassifAIRealtimeSession: NSObject, ObservableObject {
  enum State: Equatable {
    case disconnected
    case connecting
    case listening
    case thinking
    case speaking
    case failed(String)
  }

  @Published private(set) var state: State = .disconnected
  @Published private(set) var userTranscript = ""
  @Published private(set) var assistantCaption = ""

  var isActive: Bool {
    switch state {
    case .connecting, .listening, .thinking, .speaking: true
    case .disconnected, .failed: false
    }
  }

  private let factory = LKRTCPeerConnectionFactory()
  private var peer: LKRTCPeerConnection?
  private var dataChannel: LKRTCDataChannel?
  private var audioTrack: LKRTCAudioTrack?
  private var latestVisionJPEG: Data?
  private var latestVisionDate = Date.distantPast
  private var visionTask: Task<Void, Never>?
  private var sidebandEventTask: Task<Void, Never>?
  private var streamingCaptionRole = ""
  private var streamingCaptionMessageId = ""
  private var streamingCaptionText = ""

  func start() async {
    guard !isActive else { return }
    state = .connecting
    userTranscript = ""
    assistantCaption = ""
    streamingCaptionRole = ""
    streamingCaptionMessageId = ""
    streamingCaptionText = ""

    do {
      try configureAudioSession()
      let configuration = LKRTCConfiguration()
      configuration.sdpSemantics = .unifiedPlan
      configuration.bundlePolicy = .maxBundle
      configuration.continualGatheringPolicy = .gatherContinually
      let constraints = LKRTCMediaConstraints(
        mandatoryConstraints: nil,
        optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
      guard let peer = factory.peerConnection(
        with: configuration,
        constraints: constraints,
        delegate: self) else {
        throw RealtimeError.peerCreationFailed
      }
      self.peer = peer

      let audioConstraints = LKRTCMediaConstraints(
        mandatoryConstraints: [
          "googEchoCancellation": "true",
          "googAutoGainControl": "true",
          "googNoiseSuppression": "true",
        ],
        optionalConstraints: nil)
      let source = factory.audioSource(with: audioConstraints)
      let audioTrack = factory.audioTrack(with: source, trackId: "glassifai-audio")
      self.audioTrack = audioTrack
      guard peer.add(audioTrack, streamIds: ["glassifai"]) != nil else {
        throw RealtimeError.audioTrackFailed
      }

      let videoTransceiver = LKRTCRtpTransceiverInit()
      videoTransceiver.direction = .sendOnly
      guard peer.addTransceiver(of: .video, init: videoTransceiver) != nil else {
        throw RealtimeError.peerCreationFailed
      }

      let channelConfiguration = LKRTCDataChannelConfiguration()
      channelConfiguration.isOrdered = true
      channelConfiguration.isNegotiated = true
      channelConfiguration.channelId = 0
      guard let channel = peer.dataChannel(forLabel: "", configuration: channelConfiguration) else {
        throw RealtimeError.dataChannelFailed
      }
      channel.delegate = self
      dataChannel = channel

      let offer = try await createOffer(peer: peer, constraints: constraints)
      try await setLocalDescription(offer, peer: peer)
      for _ in 0..<25 where peer.iceGatheringState != .complete {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      let localSDP = peer.localDescription?.sdp ?? offer.sdp
      let answerSDP = try await createDirectRealtimeCall(sdp: localSDP)
      let answer = LKRTCSessionDescription(type: .answer, sdp: answerSDP)
      try await setRemoteDescription(answer, peer: peer)

      for _ in 0..<100 where channel.readyState != .open {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      guard channel.readyState == .open else { throw RealtimeError.connectionTimedOut }
      state = .listening
      startSidebandEventLoop()
    } catch {
      await tearDown()
      state = .failed(error.localizedDescription)
    }
  }

  func stop() async {
    sendEvent(["type": "session.close"])
    await tearDown()
    state = .disconnected
  }

  func submitVisionJPEG(_ jpeg: Data) {
    guard jpeg.count <= 1_500_000 else { return }
    latestVisionJPEG = jpeg
    latestVisionDate = Date()
  }

  func stopSpeaking() {
    sendEvent([
      "type": "action_request",
      "payload": ["action": "stop_speaking"],
    ])
    if isActive { state = .listening }
  }

  private func createDirectRealtimeCall(sdp: String) async throws -> String {
    let tokens = try await ChatGPTAuthSession.shared.freshTokens()
    let result = try await EmbeddedCodexBridge.startRealtime(tokens: tokens, sdp: sdp)
    guard result.ok, let answer = result.sdp,
          answer.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("v=0") else {
      throw RealtimeError.signalingFailed(
        "Embedded Codex could not start ChatGPT Live. \(result.error ?? "Unknown error")")
    }
    return answer
  }

  private func startSidebandEventLoop() {
    sidebandEventTask?.cancel()
    sidebandEventTask = Task { [weak self] in
      var ticks = 0
      while !Task.isCancelled {
        while let event = EmbeddedCodexBridge.nextSidebandEvent() {
          self?.handleDelegation(event)
        }
        if ticks.isMultiple(of: 10) {
          let status = EmbeddedCodexBridge.sidebandStatus()
          if status.contains("failed") || status.hasPrefix("server error") || status == "server closed" {
            self?.state = .failed("The visual context channel disconnected. Tap to reconnect.")
            return
          }
        }
        ticks += 1
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
  }


  private func handleDelegation(_ event: [String: Any]) {
    guard let item = event["item"] as? [String: Any],
          item["type"] as? String == "delegation",
          item["target"] as? String == "client",
          let handoffId = item["id"] as? String else { return }
    let content = item["content"] as? [[String: Any]] ?? []
    let question = content.compactMap { entry -> String? in
      guard entry["type"] as? String == "input_text" else { return nil }
      return entry["text"] as? String
    }.joined()
    visionTask?.cancel()
    visionTask = Task { [weak self] in
      guard let self else { return }
      let result: String
      do {
        result = try await inspectCurrentView(question: question)
      } catch {
        result = "I could not inspect the current view. Ask the user to hold still and try again."
      }
      guard !Task.isCancelled else { return }
      sendDelegationContext(result, handoffId: handoffId)
    }
  }

  private func sendDelegationContext(_ text: String, handoffId: String) {
    guard EmbeddedCodexBridge.completeDelegation(handoffId: handoffId, text: text) else {
      state = .failed("The visual context channel disconnected. Tap to reconnect.")
      return
    }
  }


  private func inspectCurrentView(question: String) async throws -> String {
    guard let jpeg = latestVisionJPEG,
          Date().timeIntervalSince(latestVisionDate) <= 10 else {
      return "No fresh camera frame is available. Ask the user to point the camera and try again."
    }
    let tokens = try await ChatGPTAuthSession.shared.freshTokens()
    let available = ChatGPTAuthSession.shared.availableModels
    guard let model = available.first(where: { $0 == "gpt-5.6-sol" }) ?? available.first else {
      throw RealtimeError.noModel
    }
    var components = URLComponents(
      url: ChatGPTAPI.codexBase.appending(path: "responses"),
      resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "client_version", value: ChatGPTAPI.clientVersion)]
    guard let url = components.url else { throw RealtimeError.invalidResponse }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 45
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
    for (name, value) in try ChatGPTAPI.codexHeaders(tokens: tokens) {
      request.setValue(value, forHTTPHeaderField: name)
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": model,
      "stream": true,
      "store": false,
      "instructions":
        "You are GlassifAI visual perception. Answer only from the current image, briefly and concretely. " +
        "State uncertainty instead of guessing.",
      "reasoning": ["effort": "low", "summary": "auto"],
      "text": ["verbosity": "low"],
      "include": ["reasoning.encrypted_content"],
      "input": [[
        "role": "user",
        "content": [
          ["type": "input_text", "text": question.isEmpty ? "Describe the current view." : question],
          ["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
        ],
      ]],
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          let body = String(data: data, encoding: .utf8) else {
      throw RealtimeError.visionFailed
    }
    let text = Self.parseResponsesText(body).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw RealtimeError.visionFailed }
    return String(text.prefix(2_000))
  }

  private func tearDown() async {
    visionTask?.cancel()
    sidebandEventTask?.cancel()
    sidebandEventTask = nil
    visionTask = nil
    EmbeddedCodexBridge.closeRealtime()
    dataChannel?.delegate = nil
    dataChannel?.close()
    dataChannel = nil
    audioTrack?.isEnabled = false
    audioTrack = nil
    peer?.delegate = nil
    peer?.close()
    peer = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
    try session.setActive(true)
  }

  private func createOffer(
    peer: LKRTCPeerConnection,
    constraints: LKRTCMediaConstraints
  ) async throws -> LKRTCSessionDescription {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LKRTCSessionDescription, Error>) in
      peer.offer(for: constraints) { description, error in
        if let description { continuation.resume(returning: description) }
        else { continuation.resume(throwing: error ?? RealtimeError.offerFailed) }
      }
    }
  }

  private func setLocalDescription(
    _ description: LKRTCSessionDescription,
    peer: LKRTCPeerConnection
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peer.setLocalDescription(description) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }

  private func setRemoteDescription(
    _ description: LKRTCSessionDescription,
    peer: LKRTCPeerConnection
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peer.setRemoteDescription(description) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }

  private func sendEvent(_ event: [String: Any]) {
    guard let dataChannel, dataChannel.readyState == .open,
          let inner = try? JSONSerialization.data(withJSONObject: event),
          let innerText = String(data: inner, encoding: .utf8),
          let outer = try? JSONSerialization.data(withJSONObject: [
            "type": "data_message",
            "data": innerText,
          ]) else { return }
    _ = dataChannel.sendData(LKRTCDataBuffer(data: outer, isBinary: false))
  }

  private func handleDataChannelData(_ data: Data) {
    guard var value = try? JSONSerialization.jsonObject(with: data) else { return }
    for _ in 0..<4 {
      if let text = value as? String, let nested = text.data(using: .utf8),
         let decoded = try? JSONSerialization.jsonObject(with: nested) {
        value = decoded
      } else if let envelope = value as? [String: Any],
                envelope["type"] as? String == "data_message",
                let nested = envelope["data"] as? String,
                let nestedData = nested.data(using: .utf8),
                let decoded = try? JSONSerialization.jsonObject(with: nestedData) {
        value = decoded
      } else {
        break
      }
    }
    guard let event = value as? [String: Any], let type = event["type"] as? String else { return }
    let payload = event["payload"] as? [String: Any] ?? event
    switch type {
    case "chat_message_delta":
      applyChatMessageDelta(event: event, payload: payload)
    case "session.started", "session.updated":
      state = .listening
    case "state_update":
      if let next = payload["new_state"] as? String { applyLegacyState(next) }
    case "input_transcript.added":
      if let text = (event["item"] as? [String: Any])?["text"] as? String {
        userTranscript += text
      }
    case "output_transcript.added":
      if let text = (event["item"] as? [String: Any])?["text"] as? String {
        assistantCaption += text
        state = .speaking
      }
    case "turn.done":
      if let turn = event["turn"] as? [String: Any],
         let role = turn["role"] as? String,
         let text = turn["transcript"] as? String {
        if role == "user" { userTranscript = text; state = .thinking }
        if role == "assistant" { assistantCaption = text; state = .listening }
      }
    case "delegation.created":
      state = .thinking
      handleDelegation(event)
    case "user_transcription_text":
      let text = (payload["text"] ?? payload["transcript"]) as? String ?? userTranscript
      userTranscript = text
    case "live_captioning_text":
      assistantCaption = (payload["text"] ?? payload["transcript"]) as? String ?? assistantCaption
    case "error":
      state = .failed((event["message"] as? String) ?? "ChatGPT Live reported an error.")
    case "goodbye", "close_ready":
      Task { await stop() }
    default:
      break
    }
  }


  private func applyChatMessageDelta(
    event: [String: Any],
    payload: [String: Any]
  ) {
    let source = payload["type"] as? String == "chat_message_delta" ? payload : event
    let delta = source["delta"] as? [String: Any]
      ?? (source["payload"] as? [String: Any])?["delta"] as? [String: Any]
      ?? [:]
    if let value = delta["v"] as? [String: Any],
       let message = value["message"] as? [String: Any] {
      let parts = (message["content"] as? [String: Any])?["parts"] as? [Any] ?? []
      var role = (message["author"] as? [String: Any])?["role"] as? String ?? ""
      if role != "user" && role != "assistant" {
        for case let part as [String: Any] in parts
        where part["content_type"] as? String == "audio_transcription" {
          if part["direction"] as? String == "in" { role = "user" }
          if part["direction"] as? String == "out" { role = "assistant" }
        }
      }
      guard role == "user" || role == "assistant" else { return }
      let text = parts.compactMap { part -> String? in
        if let text = part as? String { return text }
        guard let part = part as? [String: Any] else { return nil }
        return part["text"] as? String
          ?? part["content"] as? String
          ?? part["transcript"] as? String
      }.joined(separator: "\n")
      streamingCaptionRole = role
      streamingCaptionMessageId = message["id"] as? String ?? streamingCaptionMessageId
      streamingCaptionText = text
    } else if let operations = delta["v"] as? [[String: Any]],
              !streamingCaptionRole.isEmpty {
      for operation in operations
      where operation["o"] as? String == "append" {
        let path = operation["p"] as? String ?? ""
        guard path.range(of: #"^/message/content/parts/\d+/text$"#, options: .regularExpression) != nil else {
          continue
        }
        streamingCaptionText += operation["v"] as? String ?? ""
      }
    }
    guard !streamingCaptionText.isEmpty else { return }
    if streamingCaptionRole == "user" {
      userTranscript = streamingCaptionText
    } else if streamingCaptionRole == "assistant" {
      assistantCaption = streamingCaptionText
      state = .speaking
    }
  }
  private func applyLegacyState(_ next: String) {
    switch next {
    case "listening", "listening_intently", "connected", "idle": state = .listening
    case "thinking": state = .thinking
    case "speaking": state = .speaking
    case "halted": state = .disconnected
    default: break
    }
  }

  private static func parseResponsesText(_ body: String) -> String {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.hasPrefix("data:") && !trimmed.hasPrefix("event:") {
      guard let data = body.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
      return json["output_text"] as? String ?? ""
    }
    var output = ""
    for line in body.split(separator: "\n") where line.hasPrefix("data:") {
      let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
      guard raw != "[DONE]", let data = raw.data(using: .utf8),
            let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      if event["type"] as? String == "response.output_text.delta", let delta = event["delta"] as? String {
        output += delta
      }
    }
    return output
  }

  private static let realtimePrompt =
    "You are GlassifAI, a calm, fast, eyes-free assistant for smart glasses. Keep speech concise, " +
    "natural, and interruptible. Never pretend to see. Whenever the user refers to what they see, " +
    "asks about an object, scene, sign, document, person, color, or location, delegate to the client " +
    "for current visual context. Use the returned speakable context to answer naturally."
}

extension GlassifAIRealtimeSession: LKRTCPeerConnectionDelegate {
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
  nonisolated func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
    if newState == .failed {
      Task { @MainActor in
        await tearDown()
        state = .failed("The voice connection was interrupted. Tap to reconnect.")
      }
    }
  }
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}

extension GlassifAIRealtimeSession: LKRTCDataChannelDelegate {
  nonisolated func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {}
  nonisolated func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
    let data = buffer.data
    Task { @MainActor in handleDataChannelData(data) }
  }
}


private enum RealtimeError: LocalizedError {
  case peerCreationFailed
  case audioTrackFailed
  case dataChannelFailed
  case offerFailed
  case invalidResponse
  case connectionTimedOut
  case noModel
  case visionFailed
  case signalingFailed(String)

  var errorDescription: String? {
    switch self {
    case .peerCreationFailed: "The voice connection could not be created."
    case .audioTrackFailed: "The microphone could not join the voice connection."
    case .dataChannelFailed: "The ChatGPT event channel could not be created."
    case .offerFailed: "The iPhone could not create a voice offer."
    case .invalidResponse: "ChatGPT returned an invalid response."
    case .connectionTimedOut: "ChatGPT took too long to connect."
    case .noModel: "No compatible ChatGPT model is available."
    case .visionFailed: "The current view could not be inspected."
    case .signalingFailed(let message): message
    }
  }
}
