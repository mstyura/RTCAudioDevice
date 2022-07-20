import Foundation
import WebRTC
import AVFoundation

final class AUAudioUnitRTCAudioDevice: NSObject {
  let audioSession = AVAudioSession.sharedInstance()
  private let queue = DispatchQueue(label: "AUAudioUnitRTCAudioDevice")

  private var audioUnit: AUAudioUnit?
  private var audioUnitRenderBlock: AURenderBlock?
  private var subscribtions: [Any]?
  private var shouldPlay = false
  private var shouldRecord = false

  private var isInterrupted_ = false
  private var isInterrupted: Bool {
    get {
      queue.sync {
        isInterrupted_
      }
    }
    set {
      queue.sync {
        isInterrupted_ = newValue
      }
    }
  }

  var delegate_: RTCAudioDeviceDelegate?
  private var delegate: RTCAudioDeviceDelegate? {
    get {
      queue.sync {
        delegate_
      }
    }
    set {
      queue.sync {
        delegate_ = newValue
      }
    }
  }

  private lazy var audioInputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                    sampleRate: audioSession.sampleRate,
                                                    channels: AVAudioChannelCount(min(2, audioSession.inputNumberOfChannels)),
                                                    interleaved: true) {
    didSet {
      guard oldValue != audioInputFormat else { return }
      delegate?.notifyAudioInputParametersChange()
    }
  }

  private lazy var audioOutputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                     sampleRate: audioSession.sampleRate,
                                                     channels: AVAudioChannelCount(min(2, audioSession.outputNumberOfChannels)),
                                                     interleaved: true) {
    didSet {
      guard oldValue != audioOutputFormat else { return }
      delegate?.notifyAudioOutputParametersChange()
    }
  }

  private (set) lazy var inputLatency = audioSession.inputLatency {
    didSet {
      guard oldValue != inputLatency else { return }
      delegate?.notifyAudioInputParametersChange()
    }
  }
  
  private (set) lazy var outputLatency = audioSession.outputLatency {
    didSet {
      guard oldValue != outputLatency else { return }
      delegate?.notifyAudioOutputParametersChange()
    }
  }

  override init() {
    super.init()
  }

  private func updateAudioUnit() {
    guard let audioUnit = audioUnit else {
      return
    }

    audioUnit.dumpState(label: "Before audio unit update")

    let stopAudioUnit = { (label: String) in
      if audioUnit.isRunning {
        measureTime(label: "AVAudioUnit stop hardware to \(label)") {
          audioUnit.stopHardware()
          guard let delegate = self.delegate else {
            return
          }
          delegate.notifyAudioInputInterrupted()
          delegate.notifyAudioOutputInterrupted()
        }
      }
    }

    let stopAndUnitializeAudioUnit = { (label: String) in
      stopAudioUnit(label)
      if audioUnit.renderResourcesAllocated {
        measureTime(label: "AVAudioUnit deallocate render resources to \(label)") {
          audioUnit.deallocateRenderResources()
        }
      }
    }

    guard let delegate = delegate, shouldPlay || shouldRecord, !isInterrupted else {
      stopAndUnitializeAudioUnit("turn off audio unit")
      return
    }

    if audioUnit.isInputEnabled != shouldRecord {
      stopAndUnitializeAudioUnit("toggle input")
      measureTime(label: "AVAudioUnit toggle input") {
        audioUnit.isInputEnabled = shouldRecord
      }
    }

    if audioUnit.isOutputEnabled != shouldPlay {
      stopAndUnitializeAudioUnit("toggle output")
      measureTime(label: "AVAudioUnit toggle output") {
        audioUnit.isOutputEnabled = shouldPlay
      }
    }
    

    let hardwareSampleRate = audioSession.sampleRate
    if shouldRecord {
      let rtcRecordFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: hardwareSampleRate,
        channels: AVAudioChannelCount(min(2, audioSession.inputNumberOfChannels)),
        interleaved: true)!

      let bus = 1
      let outputBus = audioUnit.outputBusses[bus]
      if outputBus.format != rtcRecordFormat {
        stopAndUnitializeAudioUnit("Stop to update recording format of audioUnit.outputBusses[\(bus)]")
        measureTime(label: "Update recording format of audioUnit.outputBusses[\(bus)]") {
          do {
            try outputBus.setFormat(rtcRecordFormat)
            print("Record format set to: \(rtcRecordFormat)")
          } catch let e {
            print("Failed update audioUnit.outputBusses[\(bus)].format of audio unit: \(e)")
            return
          }
        }
      }
      audioInputFormat = rtcRecordFormat

      measureTime(label: "AVAudioUnit define inputHandler") {
        let deliverRecordedData = delegate.deliverRecordedData
        let renderBlock = audioUnit.renderBlock
        let customRenderBlock = { actionFlags, timestamp, inputBusNumber, frameCount, abl in
          return renderBlock(actionFlags, timestamp, frameCount, inputBusNumber, abl, nil)
        }
        audioUnit.inputHandler = { actionFlags, timestamp, frameCount, inputBusNumber in
          let status = deliverRecordedData(actionFlags, timestamp, inputBusNumber, frameCount, nil, customRenderBlock)
          if status != noErr {
            print("Failed to deliver audio data: \(status)")
          }
        }
      }
      inputLatency = audioSession.inputLatency
    }
  
    if shouldPlay {
      let rtcPlayFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: hardwareSampleRate,
        channels: AVAudioChannelCount(min(2, audioSession.outputNumberOfChannels)),
        interleaved: true)!
      let bus = 0;
      let inputBus = audioUnit.inputBusses[bus]
      if inputBus.format != rtcPlayFormat {
        stopAndUnitializeAudioUnit("Stop to update recording format of audioUnit.outputBusses[\(bus)]")
        measureTime(label: "Update playout format of audioUnit.inputBusses[\(bus)]") {
          do {
            try inputBus.setFormat(rtcPlayFormat)
            print("Play format set to: \(rtcPlayFormat)")
          } catch let e {
            print("Failed update audioUnit.inputBusses[\(bus)].format of audio unit: \(e)")
            return
          }
        }
      }
      audioOutputFormat = rtcPlayFormat

      if audioUnit.outputProvider == nil {
        measureTime(label: "AVAudioUnit define outputProvider") {
          let getPlayoutData = delegate.getPlayoutData
          // NOTE: No need to stop or unitialized AU before change property
          audioUnit.outputProvider = { (actionFlags, timestamp, frameCount, inputBusNumber, inputData) -> AUAudioUnitStatus in
            return getPlayoutData(actionFlags, timestamp, inputBusNumber, frameCount, inputData)
          }
        }
      }
      outputLatency = audioSession.outputLatency
    }

    if !audioUnit.renderResourcesAllocated {
      measureTime(label: "AVAudioUnit allocate render resources") {
        do {
          try audioUnit.allocateRenderResources()
        }
        catch let e {
          print("allocateRenderResources error: \(e)")
          return
        }
      }
    }
    if !audioUnit.isRunning {
      measureTime(label: "AVAudioUnit start hardware") {
        do {
          try audioUnit.startHardware()
        }
        catch let e {
          print("startHardware error: \(e)")
          return
        }
      }
    }
    audioUnit.dumpState(label: "After audio unit update")
  }
}


extension AUAudioUnitRTCAudioDevice: RTCAudioDevice {

  var inputSampleRate: Double {
    guard let sampleRate = audioInputFormat?.sampleRate, sampleRate > 0 else {
      return audioSession.sampleRate
    }
    return sampleRate
  }

  var outputSampleRate: Double {
    guard let sampleRate = audioOutputFormat?.sampleRate, sampleRate > 0 else {
      return audioSession.sampleRate
    }
    return sampleRate
  }

  var inputIOBufferDuration: TimeInterval { audioSession.ioBufferDuration }

  var outputIOBufferDuration: TimeInterval { audioSession.ioBufferDuration }

  var inputNumberOfChannels: Int {
    guard let channelCount = audioInputFormat?.channelCount, channelCount > 0 else {
      return min(2, audioSession.inputNumberOfChannels)
    }
    return Int(channelCount)
  }

  var outputNumberOfChannels: Int {
    guard let channelCount = audioOutputFormat?.channelCount, channelCount > 0 else {
      return min(2, audioSession.outputNumberOfChannels)
    }
    return Int(channelCount)
  }

  var isInitialized: Bool {
    delegate != nil && audioUnit != nil
  }

  func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
    guard self.delegate == nil else {
      return false
    }

    let description = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: audioSession.supportsVoiceProcessing ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_RemoteIO,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0);
    
    let audioUnit: AUAudioUnit
    do {
      audioUnit = try AUAudioUnit.init(componentDescription: description)
    } catch let e {
      print("Failed init audio unit: \(e)")
      return false
    }
    audioUnit.isInputEnabled = false
    audioUnit.isOutputEnabled = false
    audioUnit.maximumFramesToRender = 1024
    
    if subscribtions == nil {
      subscribtions = subscribeAudioSessionNotifications()
    }
    if !audioSession.supportsVoiceProcessing {
      configureStereoRecording()
    }
    
    self.audioUnit = audioUnit
    self.delegate = delegate
    return true
  }

  func terminate() -> Bool {
    if let subscribtions = subscribtions {
      unsubscribeAudioSessionNotifications(observers: subscribtions)
    }
    subscribtions = nil

    shouldPlay = false
    shouldRecord = false
    updateAudioUnit()

    audioUnit = nil
    return true
  }

  var isPlayoutInitialized: Bool {
    isInitialized
  }

  func initializePlayout() -> Bool {
    return isPlayoutInitialized
  }

  var isPlaying: Bool {
    self.shouldPlay
  }

  func startPlayout() -> Bool {
    shouldPlay = true
    updateAudioUnit()
    
    return true
  }
  
  func stopPlayout() -> Bool {
    shouldPlay = false
    updateAudioUnit()
 
    return true
  }
  
  var isRecordingInitialized: Bool {
    isInitialized
  }

  func initializeRecording() -> Bool {
    isRecordingInitialized
  }

  var isRecording: Bool {
    shouldRecord
  }
  
  func startRecording() -> Bool {
    shouldRecord = true
    updateAudioUnit()
    return true
  }
  
  func stopRecording() -> Bool {
    shouldRecord = false
    updateAudioUnit()
    return true
  }
}

extension AUAudioUnitRTCAudioDevice: AudioSessionHandler {
  func handleInterruptionBegan(applicationWasSuspended: Bool) {
    guard !applicationWasSuspended else {
      // NOTE: Not an actual interruption
      return
    }
    self.isInterrupted = true
    guard let delegate = delegate else {
      return
    }
    delegate.dispatchAsync {
      measureTime {
        self.updateAudioUnit()
      }
    }
  }
  
  func handleInterruptionEnd(shouldResume: Bool) {
    self.isInterrupted = false
    guard let delegate = delegate else {
      return
    }
    delegate.dispatchAsync {
      measureTime {
        self.updateAudioUnit()
      }
    }
  }

  func handleAudioRouteChange() {
    guard let delegate = delegate else {
      return
    }
    delegate.dispatchAsync {
      measureTime {
        self.updateAudioUnit()
      }
    }
  }
  
  func handleMediaServerWereReset() {
    guard let delegate = delegate else {
      return
    }
    delegate.dispatchAsync {
      measureTime {
        self.updateAudioUnit()
      }
    }
  }
  
  func handleMediaServerWereLost() {
  }
}

