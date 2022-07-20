//
//  SimulateStream.swifft.swift
//  CustomRTCAudioDevice
//
//  Created by Yury Yarashevich on 29.04.22.
//

import Foundation
import WebRTC

enum RTCAudioDeviceKind {
  case auAudioUnit
  case avAudioEngine
}


func makePeerConnectionFactory(audioDeviceKind: RTCAudioDeviceKind) -> RTCPeerConnectionFactory {
  let device: RTCAudioDevice
  switch audioDeviceKind {
  case .auAudioUnit:
    device = AUAudioUnitRTCAudioDevice()
  case .avAudioEngine:
    device = AVAudioEngineRTCAudioDevice()
  }
  let factory = RTCPeerConnectionFactory(
    encoderFactory: RTCDefaultVideoEncoderFactory(),
    decoderFactory: RTCDefaultVideoDecoderFactory(),
    audioDevice: device)

  let options = RTCPeerConnectionFactoryOptions()
  options.ignoreCellularNetworkAdapter = true
  options.ignoreVPNNetworkAdapter = true
  options.ignoreEthernetNetworkAdapter = true
  options.ignoreWiFiNetworkAdapter = true
  options.ignoreLoopbackNetworkAdapter = false
  factory.setOptions(options)
  return factory
}

actor SimulateStream: NSObject {
  private let peerConnectionFactory: RTCPeerConnectionFactory

  private nonisolated let config = RTCConfiguration()
  private nonisolated let contraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
  
  private lazy var broadcaster = peerConnectionFactory.peerConnection(with: config, constraints: contraints, delegate: self)
  
  private var broadcasterAudioTrack: RTCAudioTrack?
  
  private lazy var viewer = peerConnectionFactory.peerConnection(with: config, constraints: contraints, delegate: self)
  
  init(audioDeviceKind: RTCAudioDeviceKind) {

    peerConnectionFactory = makePeerConnectionFactory(audioDeviceKind: audioDeviceKind)

    super.init()
  }
  
  func start() async throws {
    let broadcaster = self.broadcaster!
    let viewer = self.viewer!
  
    let tranInit = RTCRtpTransceiverInit()
    tranInit.direction = .sendOnly
    broadcaster.addTransceiver(of: .audio, init: tranInit)
    
    try await broadcaster.setLocalDescription()
    
    try await viewer.setRemoteDescription(broadcaster.localDescription!)
    
    try await viewer.setLocalDescription()
    
    try await broadcaster.setRemoteDescription(viewer.localDescription!)
    
    assert(viewer.signalingState == .stable)
    assert(broadcaster.signalingState == .stable)
  }

  func stop() {
    self.broadcaster!.close()
    self.viewer!.close()
  }

  var isRecording: Bool {
    broadcasterAudioTrack != nil
  }

  func startRecording() {
    guard let tran = broadcaster?.transceivers.first else {
      return
    }
    guard broadcasterAudioTrack == nil else {
      return
    }

    broadcasterAudioTrack = peerConnectionFactory.audioTrack(withTrackId: "audio-track")
    tran.sender.track = broadcasterAudioTrack
    print("Started recording")
  }

  func stopRecording() {
    guard let tran = broadcaster?.transceivers.first else {
      return
    }
    tran.sender.track = nil
    self.broadcasterAudioTrack = nil
    print("Stopped recording")

  }
}


extension SimulateStream: RTCPeerConnectionDelegate {
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
    
  }
  
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
    
  }
  
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
    
  }
  
  nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
    
  }
  
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
    
  }
  
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
    
  }
  
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
    Task {
      guard let broadcaster = await self.broadcaster,
            let viewer = await self.viewer else {
        return;
      }
      if peerConnection == broadcaster {
        try await viewer.add(candidate)
      } else {
        try await broadcaster.add(candidate)
      }
    }
  }
  
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
    
  }
  
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
    
  }
}
