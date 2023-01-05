import Foundation
import WebRTC
import AVFoundation

// NOTE: Does not cover all corner cases with audio session interruptions, switch between devices etc.
// Please use only as an example
final class AVAudioEngineRTCAudioDevice: NSObject {
  let audioSession = AVAudioSession.sharedInstance()
  private var subscribtions: [Any]?

  private let queue = DispatchQueue(label: "AVAudioEngineRTCAudioDevice")

  private lazy var backgroundPlayer = AVAudioPlayerNode()
  private var backgroundSound: AVAudioPCMBuffer?

  private var audioEngine: AVAudioEngine?
  private var audioEngineObserver: Any?
  private var inputEQ = AVAudioUnitEQ(numberOfBands: 2)

  private var audioConverer: AVAudioConverter?
  private var audioSinkNode: AVAudioSinkNode?
  private var audioSourceNode: AVAudioSourceNode?
  private var shouldPlay = false
  private var shouldRecord = false

  private lazy var audioInputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                    sampleRate: audioSession.sampleRate,
                                                    channels: AVAudioChannelCount(min(2, audioSession.inputNumberOfChannels)),
                                                    interleaved: false) {
    didSet {
      guard oldValue != audioInputFormat else { return }
      delegate?.notifyAudioInputParametersChange()
    }
  }

  private lazy var audioOutputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                     sampleRate: audioSession.sampleRate,
                                                     channels: AVAudioChannelCount(min(2, audioSession.outputNumberOfChannels)),
                                                     interleaved: false) {
    didSet {
      guard oldValue != audioOutputFormat else { return }
      delegate?.notifyAudioOutputParametersChange()
    }
  }

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

  private func shutdownEngine() {
    guard let audioEngine = audioEngine else {
      return
    }
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    if let audioEngineObserver = audioEngineObserver {
      NotificationCenter.default.removeObserver(audioEngineObserver)
      self.audioEngineObserver = nil
    }
    if let audioSinkNode = self.audioSinkNode {
      audioEngine.detach(audioSinkNode)
      self.audioSinkNode = nil
      delegate?.notifyAudioInputInterrupted()
    }
    if let audioSourceNode = audioSourceNode {
      audioEngine.detach(audioSourceNode)
      self.audioSourceNode = nil
      delegate?.notifyAudioOutputInterrupted()
    }
    self.audioEngine = nil
  }

  private func updateEngine()  {
    guard let delegate = delegate,
          shouldPlay || shouldRecord,
          !isInterrupted else {
      print("Audio Engine must be stopped: shouldPla=\(shouldPlay), shouldRecord=\(shouldRecord), isInterrupted=\(isInterrupted)")
      measureTime(label: "Shutdown AVAudioEngine") {
        shutdownEngine()
      }
      return
    }

    if let audioEngine = audioEngine, !audioEngine.isInputOutputSampleRatesNativeFor(audioSession: audioSession) {
      print("Shutdown AVAudioEngine to match HW format")
      shutdownEngine()
    }

    let useVoiceProcessingAudioUnit = audioSession.supportsVoiceProcessing
    if let audioEngine = audioEngine, audioEngine.inputNode.isVoiceProcessingEnabled != useVoiceProcessingAudioUnit {
      print("Shutdown AVAudioEngine to toggle usage of Voice Processing I/O")
      shutdownEngine()
    }

    var audioEngine: AVAudioEngine
    if let engine = self.audioEngine {
      audioEngine = engine
    } else {
      if !useVoiceProcessingAudioUnit {
        configureStereoRecording()
      }

      audioEngine = AVAudioEngine()
      audioEngine.isAutoShutdownEnabled = true
      // NOTE: Toggle voice processing state over outputNode, not to eagerly create inputNote.
      // Also do it just after creation of AVAudioEngine to avoid random crashes observed when voice processing changed on later stages.
      if audioEngine.outputNode.isVoiceProcessingEnabled != useVoiceProcessingAudioUnit {
        do {
          // Use VPIO to as I/O audio unit.
          try audioEngine.outputNode.setVoiceProcessingEnabled(useVoiceProcessingAudioUnit)
        }
        catch let e {
          print("setVoiceProcessingEnabled error: \(e)")
          return
        }
      }
      audioEngine.attach(backgroundPlayer)
      audioEngine.attach(inputEQ)

      audioEngineObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.AVAudioEngineConfigurationChange,
                                                                   object: audioEngine,
                                                                   queue: nil,
                                                                   using: { [weak self] notification in
          self?.handleAudioEngineConfigurationChanged()
      })

      audioEngine.dumpState(label: "State of newly created audio engine")
      self.audioEngine = audioEngine
    }

    let shouldBypassVoiceProcessing = shouldRecord && !shouldPlay
    if useVoiceProcessingAudioUnit {
      if audioEngine.inputNode.isVoiceProcessingBypassed != shouldBypassVoiceProcessing {
        measureTime(label: "Change bypass voice processing") {
          audioEngine.inputNode.isVoiceProcessingBypassed = shouldBypassVoiceProcessing
        }
      }
    }

    let ioAudioUnit = audioEngine.outputNode.auAudioUnit
    if ioAudioUnit.isInputEnabled != shouldRecord ||
        ioAudioUnit.isOutputEnabled != shouldPlay {
      if audioEngine.isRunning {
        measureTime(label: "AVAudioEngine stop (to enable/disable AUAudioUnit output/input)") {
          audioEngine.stop()
        }
      }

      measureTime(label: "Change input/output enabled/disabled") {
        ioAudioUnit.isInputEnabled = shouldRecord
        ioAudioUnit.isOutputEnabled = shouldPlay
      }
    }

    if shouldRecord {
      if audioSinkNode == nil {
        measureTime(label: "Add AVAudioSinkNode") {
          let deliverRecordedData = delegate.deliverRecordedData
          let inputFormat = audioEngine.inputNode.outputFormat(forBus: 1)
          guard inputFormat.isSampleRateAndChannelCountValid else {
            print("Invalid input format: \(inputFormat)")
            return
          }
          audioEngine.connect(audioEngine.inputNode, to: inputEQ, format: inputFormat)

          let rtcRecordFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: inputFormat.sampleRate,
                                              channels: inputFormat.channelCount,
                                              interleaved: true)!
          audioInputFormat = rtcRecordFormat
          inputLatency = audioSession.inputLatency

          // NOTE: AVAudioSinkNode provides audio data with HW sample rate in 32-bit float format,
          // WebRTC requires 16-bit int format, so do the conversion
          let converter = SimpleAudioConverter(from: inputFormat, to: rtcRecordFormat)!

          let customRenderBlock: RTCAudioDeviceRenderRecordedDataBlock = { actionFlags, timestamp, inputBusNumber, frameCount, abl, renderContext in
            let (converter, inputData) = renderContext!.assumingMemoryBound(to: (Unmanaged<SimpleAudioConverter>, UnsafeMutablePointer<AudioBufferList>).self).pointee
            return converter.takeUnretainedValue().convert(framesCount: frameCount, from: inputData, to: abl)
          }

          let audioSink = AVAudioSinkNode(receiverBlock: { (timestamp, framesCount, inputData) -> OSStatus in
            var flags: AudioUnitRenderActionFlags = []
            var renderContext = (Unmanaged.passUnretained(converter), inputData)
            return deliverRecordedData(&flags, timestamp, 1, framesCount, nil, &renderContext, customRenderBlock)
          })
    
          measureTime(label: "Attach AVAudioSinkNode") {
            audioEngine.attach(audioSink)
          }
          
          measureTime(label: "Connect AVAudioSinkNode") {
            audioEngine.connect(inputEQ, to: audioSink, format: inputFormat)
          }
          
          audioSinkNode = audioSink
        }
      }
    } else {
      if let audioSinkNode = audioSinkNode {
        audioEngine.detach(audioSinkNode)
        self.audioSinkNode = nil
      }
    }

    if shouldPlay {
      if audioSourceNode == nil {
        measureTime(label: "Add AVAudioSourceNode") {
          let outputFormat = audioEngine.outputNode.outputFormat(forBus: 0)
          guard outputFormat.isSampleRateAndChannelCountValid else {
            print("Invalid audio output format detected: \(outputFormat)")
            return
          }
          print("Playout format: \(outputFormat)")
          audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: outputFormat)

          let rtcPlayFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: outputFormat.sampleRate,
                                            channels: outputFormat.channelCount,
                                            interleaved: true)!

          audioOutputFormat = rtcPlayFormat
          inputLatency = audioSession.inputLatency

          let getPlayoutData = delegate.getPlayoutData
          let audioSource = AVAudioSourceNode(format: rtcPlayFormat,
                                              renderBlock: { (isSilence, timestamp, frameCount, outputData) -> OSStatus in
            var flags: AudioUnitRenderActionFlags = []
            let res = getPlayoutData(&flags, timestamp, 0, frameCount, outputData)
            guard noErr == res else {
              return res
            }
            isSilence.initialize(to: ObjCBool(flags.contains(AudioUnitRenderActionFlags.unitRenderAction_OutputIsSilence)))
            return noErr
          })

          measureTime(label: "Attach AVAudioSourceNode") {
            audioEngine.attach(audioSource)
          }

          measureTime(label: "Connect AVAudioSourceNode") {
            audioEngine.connect(audioSource, to: audioEngine.mainMixerNode, format: outputFormat)
          }

          self.audioSourceNode = audioSource
        }
      }
    } else {
      if let audioSourceNode = audioSourceNode {
        audioEngine.detach(audioSourceNode)
        self.audioSourceNode = nil
      }
    }

    if !audioEngine.isRunning {
      measureTime(label: "Prepare AVAudioEngine") {
        audioEngine.prepare()
      }

      measureTime(label: "Start AVAudioEngine") {
        do {
          try audioEngine.start()
        } catch let e {
          print("Unable to start audio engine: \(e)")
        }
      }

      if let backgroundSound = backgroundSound, audioEngine.isRunning, shouldPlay {
        measureTime(label: "Background music") {
          audioEngine.disconnectNodeOutput(backgroundPlayer)
          audioEngine.connect(backgroundPlayer, to: audioEngine.mainMixerNode, format: nil)
          if !backgroundPlayer.isPlaying {
            backgroundPlayer.play()
            backgroundPlayer.scheduleBuffer(backgroundSound, at: nil, options: [.loops], completionHandler: nil)
          }
        }
      }
    }

    audioEngine.dumpState(label: "After updateEngine")
  }
  
  private func handleAudioEngineConfigurationChanged() {
    guard let delegate = delegate else {
      return
    }
    delegate.dispatchAsync { [weak self] in
      self?.updateEngine()
    }
  }
}

extension AVAudioEngineRTCAudioDevice: RTCAudioDevice {

  var deviceInputSampleRate: Double {
    guard let sampleRate = audioInputFormat?.sampleRate, sampleRate > 0 else {
      return audioSession.sampleRate
    }
    return sampleRate
  }

  var deviceOutputSampleRate: Double {
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
    self.delegate != nil
  }

  func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
    guard self.delegate == nil else {
      print("Already inititlized")
      return false
    }

    if subscribtions == nil {
      subscribtions = self.subscribeAudioSessionNotifications()
    }

    self.delegate = delegate
    
    if let fxURL = Bundle.main.url(forResource: "Synth", withExtension: "aif") {
      backgroundSound = getBuffer(fileURL: fxURL)
    }
    return true
  }

  func terminateDevice() -> Bool {
    if let subscribtions = subscribtions {
      self.unsubscribeAudioSessionNotifications(observers: subscribtions)
    }
    subscribtions = nil

    shouldPlay = false
    shouldRecord = false
    measureTime {
      updateEngine()
    }
    delegate = nil
    return true
  }

  var isPlayoutInitialized: Bool { isInitialized }

  func initializePlayout() -> Bool {
    return isPlayoutInitialized
  }

  var isPlaying: Bool {
    shouldPlay
  }

  func startPlayout() -> Bool {
    print("Start playout")
    shouldPlay = true
    measureTime {
      updateEngine()
    }
    return true
  }

  func stopPlayout() -> Bool {
    print("Stop playout")
    shouldPlay = false
    measureTime {
      updateEngine()
    }
    return true
  }

  var isRecordingInitialized: Bool { isInitialized }

  func initializeRecording() -> Bool {
    return isRecordingInitialized
  }

  var isRecording: Bool {
    shouldRecord
  }

  func startRecording() -> Bool {
    print("Start recording")
    shouldRecord = true
    measureTime {
      updateEngine()
    }
    return true
  }

  func stopRecording() -> Bool {
    print("Stop recording")
    shouldRecord = false
    measureTime {
      updateEngine()
    }
    return true
  }
}

extension AVAudioEngineRTCAudioDevice: AudioSessionHandler {
  func handleInterruptionBegan(applicationWasSuspended: Bool) {
    guard !applicationWasSuspended else {
      // NOTE: Not an actual interruption
      return
    }
    isInterrupted = true
    guard let delegate = delegate else {
      return
    }
    delegate.dispatchAsync { [weak self] in
      self?.updateEngine()
    }
  }

  func handleInterruptionEnd(shouldResume: Bool) {
    isInterrupted = false
    guard let delegate = delegate else {
      return
    }
    delegate.dispatchAsync { [weak self] in
      self?.updateEngine()
    }
  }

  func handleAudioRouteChange() {
  }

  func handleMediaServerWereReset() {
  }

  func handleMediaServerWereLost() {
  }
}


