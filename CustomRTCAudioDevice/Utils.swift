//
//  Utils.swift
//  CustomRTCAudioDevice
//
//  Created by Yury Yarashevich on 12.05.22.
//

import Foundation
import AVFoundation

extension DispatchTimeInterval: CustomDebugStringConvertible {
  public var debugDescription: String {
    switch self {
    case .seconds(let secs):
      return "\(secs) secs"
    case .milliseconds(let ms):
      return "\(ms) ms"
    case .microseconds(let us):
      return "\(Double(us) / 1000.0) ms"
    case .nanoseconds(let ns):
      return "\(Double(ns) / 1_000_000.0) ms"
    case .never:
      return "never"
    @unknown default:
      return ""
    }
  }
}

func measureTime<Result>(label: String = #function, block: () -> Result) -> Result {
  let start = DispatchTime.now()
  let result = block()
  let end = DispatchTime.now()
  let duration = start.distance(to: end)
  print("Executed \(label) within \(duration.debugDescription)")
  return result
}

func getBuffer(fileURL: URL) -> AVAudioPCMBuffer? {
  let file: AVAudioFile!
  do {
    try file = AVAudioFile(forReading: fileURL)
  } catch {
    print("Could not load file: \(error)")
    return nil
  }
  file.framePosition = 0
  
  // Add 100 ms to the capacity.
  let bufferCapacity = AVAudioFrameCount(file.length)
  + AVAudioFrameCount(file.processingFormat.sampleRate * 0.1)
  guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: bufferCapacity) else { return nil }
  do {
    try file.read(into: buffer)
  } catch {
    print("Could not load file into buffer: \(error)")
    return nil
  }
  file.framePosition = 0
  return buffer
}

extension AVAudioSession {

  var supportsVoiceProcessing: Bool {
    self.category == .playAndRecord && (self.mode == .voiceChat || self.mode == .videoChat)
  }

  var describedState: String {
    var description = "AudioSession: category=\(self.category.rawValue)" +
      ", mode=\(self.mode.rawValue)" +
      ", options=\(self.categoryOptions.rawValue)" +
      ", preferredSampleRate=\(self.preferredSampleRate)" +
      ", sampleRate=\(self.sampleRate)" +
      ", preferredIOBufferDuration=\(self.preferredIOBufferDuration)" +
      ", ioBufferDuration=\(self.ioBufferDuration)" +
      ", preferredInputNumberOfChannels=\(self.preferredInputNumberOfChannels)" +
      ", isInputAvailable=\(self.isInputAvailable)" +
      ", inputNumberOfChannels=\(self.inputNumberOfChannels)" +
      ", maximumInputNumberOfChannels=\(self.maximumInputNumberOfChannels)" +
      ", preferredOutputNumberOfChannels=\(self.preferredOutputNumberOfChannels)" +
      ", outputNumberOfChannels=\(self.outputNumberOfChannels)" +
      ", maximumOutputNumberOfChannels=\(self.maximumOutputNumberOfChannels)" +
      ", allowHapticsAndSystemSoundsDuringRecording=\(self.allowHapticsAndSystemSoundsDuringRecording)"

    if #available(iOS 14.5, *) {
      description += ", prefersNoInterruptionsFromSystemAlerts=\(self.prefersNoInterruptionsFromSystemAlerts)"
    }
    description +=
      ", currentRoute=\(self.currentRoute)"
    return description
  }
}

extension AVAudioEngine {
  func dumpState(label: String) {
    print("\(label): \(self.debugDescription)")
  }
  
  func isInputOutputSampleRatesNativeFor(audioSession: AVAudioSession) -> Bool {
    let hardwareSampleRate = audioSession.sampleRate
    let inputSampleRate = self.inputNode.inputFormat(forBus: 1).sampleRate
    let outputSampleRate = self.outputNode.outputFormat(forBus: 0).sampleRate
    return inputSampleRate == hardwareSampleRate && outputSampleRate == hardwareSampleRate
  }
  
  func isInputOutputSampleRatesWorseThan(audioSession: AVAudioSession) -> Bool {
    let hardwareSampleRate = audioSession.sampleRate
    let inputSampleRate = self.inputNode.inputFormat(forBus: 1).sampleRate
    let outputSampleRate = self.outputNode.outputFormat(forBus: 0).sampleRate
    return inputSampleRate < hardwareSampleRate && outputSampleRate < hardwareSampleRate
  }
}

extension AUAudioUnit {
  func dumpState(label: String) {
    print("\(label): audioUnit.inputBusses[0].format = \(self.inputBusses[0].format)")
    print("\(label): audioUnit.inputBusses[1].format = \(self.inputBusses[1].format)")
    print("\(label): audioUnit.outputBusses[0].format = \(self.outputBusses[0].format)")
    print("\(label): audioUnit.outputBusses[1].format = \(self.outputBusses[1].format)")
  }
}

extension AVAudioFormat {
  var isSampleRateAndChannelCountValid: Bool {
    !sampleRate.isZero && !sampleRate.isNaN && sampleRate.isFinite && channelCount > 0
  }
}
