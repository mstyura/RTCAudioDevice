import Foundation
import CoreAudioTypes
import AVFAudio

public final class SimpleAudioConverter {
  public let from: AVAudioFormat
  public let to: AVAudioFormat
  private var audioConverter: AudioConverterRef?

  public init?(from: AVAudioFormat, to: AVAudioFormat) {
    guard from.sampleRate == to.sampleRate else {
      print("Sample rate conversion is not possible")
      return nil
    }
    guard noErr == AudioConverterNew(from.streamDescription, to.streamDescription, &audioConverter) else {
      return nil
    }
    self.from = from
    self.to = to
  }

  deinit {
    if let audioConverter = audioConverter {
      AudioConverterDispose(audioConverter)
    }
    audioConverter = nil
  }

  public func convert(framesCount: AVAudioFrameCount, from: UnsafePointer<AudioBufferList>, to: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
    guard let audioConverter = audioConverter else {
      preconditionFailure("Not properly inited")
    }
    let status = AudioConverterConvertComplexBuffer(audioConverter, framesCount, from, to)
    return status
  }
}
