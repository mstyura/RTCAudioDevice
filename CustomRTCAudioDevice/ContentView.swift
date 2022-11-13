//
//  ContentView.swift
//  CustomRTCAudioDevice
//
//  Created by Yury Yarashevich on 29.04.22.
//

import SwiftUI
import AVFoundation
import WebRTC

enum AudioSessionError: Error {
  case noMicrophonePermission
  case configurationError(Error)
}

func requestAudioSession(category: AVAudioSession.Category,
                         mode: AVAudioSession.Mode,
                         options: AVAudioSession.CategoryOptions) async throws {
  return try await withCheckedThrowingContinuation { cont in
    let audioSession = AVAudioSession.sharedInstance()

    audioSession.requestRecordPermission { ok in
      guard ok else {
        cont.resume(with: .failure(AudioSessionError.noMicrophonePermission))
        return
      }
      do {
        try audioSession.setCategory(category,
                                     mode: mode,
                                     policy: .default,
                                     options: options)
      } catch {
        print("Set category: \(error)")
        cont.resume(with: .failure(AudioSessionError.configurationError(error)))
        return
      }

      do {
        try audioSession.setActive(true)
      } catch {
        print("Set active: \(error)")
        cont.resume(with: .failure(AudioSessionError.configurationError(error)))
        return
      }

      print("Before \(audioSession.describedState)")

      do {
        try audioSession.setPreferredSampleRate(6 * 8000)
      } catch {
        print("Failed to setPreferredSampleRate: \(error)")
      }

      do {
        try audioSession.setPreferredIOBufferDuration(0.02)
      } catch {
        print("Failed to setPreferredIOBufferDuration: \(error)")
      }

      print("After \(audioSession.describedState)")
      cont.resume(with: .success(()))
    }
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
        Task {
          do {
            try await requestAudioSession(category: .playAndRecord,
                                          mode: .default,
                                          options: [.allowBluetoothA2DP,
                                                    .allowBluetooth,
                                                    .allowAirPlay,
                                                    .defaultToSpeaker,
                                                    .mixWithOthers,
                                                    .duckOthers,
                                                    .mixWithOthers])
          } catch {
            print(error)
          }
        }
      } label: {
        Text("Audio session playAndRecord + default (supports stereo recording)")
      }.padding()
      
      Button {
        Task {
          do {
            try await requestAudioSession(category: .playAndRecord,
                                          mode: .videoChat,
                                          options: [.allowBluetoothA2DP,
                                                    .allowBluetooth,
                                                    .allowAirPlay,
                                                    .mixWithOthers,
                                                    .duckOthers,
                                                    .mixWithOthers])
          } catch {
            print(error)
          }
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
