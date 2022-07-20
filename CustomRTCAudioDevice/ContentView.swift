//
//  ContentView.swift
//  CustomRTCAudioDevice
//
//  Created by Yury Yarashevich on 29.04.22.
//

import SwiftUI
import AVFoundation
import WebRTC

func requestAudioSession(mode: AVAudioSession.Mode, completionHandler: @escaping (AVAudioSession) -> Void) {
  let audioSession = AVAudioSession.sharedInstance()
  
  audioSession.requestRecordPermission { ok in
    guard ok else {
      return
    }
    do {
      try audioSession.setCategory(.playAndRecord, mode: mode, policy: .default, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers, .mixWithOthers,.overrideMutedMicrophoneInterruption ])
    } catch let e {
      print("Set category: \(e)")
      return
    }

    do {
      try audioSession.setActive(true)
    } catch let e {
      print("Set active: \(e)")
      return
    }

    print("Before \(audioSession.describedState)")
//    do {
//      try audioSession.setPreferredInputNumberOfChannels(1)
//    } catch let e {
//      print("Failed to setPreferredInputNumberOfChannels: \(e)")
//    }
//
//    do {
//      try audioSession.setPreferredOutputNumberOfChannels(1)
//    } catch let e {
//      print("Failed to setPreferredOutputNumberOfChannels: \(e)")
//    }

    do {
      try audioSession.setPreferredSampleRate(6 * 8000)
    } catch let e {
      print("Failed to setPreferredSampleRate: \(e)")
    }

    do {
      try audioSession.setPreferredIOBufferDuration(0.02)
    } catch let e {
      print("Failed to setPreferredIOBufferDuration: \(e)")
    }

    print("After \(audioSession.describedState)")
    completionHandler(audioSession)
  }
}

struct ContentView: View {
  @State
  var audioDeviceKind: RTCAudioDeviceKind = .auAudioUnit
  @State
  var session: SimulateStream?
  @State
  var isRecording: Bool = false

  var body: some View {
    VStack {
      if session == nil {
        Button {
          switch audioDeviceKind {
          case .auAudioUnit:
            audioDeviceKind = .avAudioEngine
          case .avAudioEngine:
            audioDeviceKind = .auAudioUnit
          }
        } label: {
          switch audioDeviceKind {
          case .auAudioUnit:
            Text("RTCAudioDevice based on AUAudioUnit will be used. Click to change.")
          case .avAudioEngine:
            Text("RTCAudioDevice based on AVAudioEngine will be used. Click to change.")
          }
        }
      } else {
        switch audioDeviceKind {
        case .auAudioUnit:
          Text("RTCAudioDevice based on AUAudioUnit in use")
        case .avAudioEngine:
          Text("RTCAudioDevice based on AVAudioEngine in use")
        }
      }

      Button {
        requestAudioSession(mode: .default) { session in
          
        }
      } label: {
        Text("Audio session playAndRecord + default (supports stereo recording)")
      }.padding()
      
      Button {
        requestAudioSession(mode: .videoChat) { session in
        }
      } label: {
        Text("Audio session playAndRecord + videoChat (supports voice processing)")
      }.padding()

      if session == nil {
        Button {
          Task {
            do {
              guard session == nil else {
                return
              }
              let session = SimulateStream(audioDeviceKind: audioDeviceKind)
              try await session.start()
              self.session = session
            } catch let e {
              print("Error: \(e)")
            }
          }
        } label: {
          Text("Start call")
        }.padding() 
      } else {
        Button {
          Task {
            guard let session = session else {
              return
            }
            await session.stop()
            self.session = nil
          }
        } label: {
          Text("Stop call")
        }.padding()

        Button {
          Task {
            if let session = session {
              if !isRecording {
                await session.startRecording()
              } else {
                await session.stopRecording()
              }
              isRecording = await session.isRecording
            }
          }
        } label: {
          if !isRecording {
            Text("Start record")
          } else {
            Text("Stop record")
          }
        }.padding()
      }

    }.padding()
  }
}

struct ContentView_Previews: PreviewProvider {
  static var previews: some View {
    ContentView()
  }
}
