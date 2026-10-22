//
//  AudioRecorder.swift
//  BetterCalendar
//
//  W38：按下麦克风录一段话 → 临时目录里的 16 kHz 单声道 WAV（Whisper 要的就是这个，省一次转码）。只在你按着的这段时间录，转完即删。
//

import AVFoundation
import Foundation

nonisolated enum AudioRecordingError: LocalizedError {
    case noPermission
    case cannotStart(String)
    var errorDescription: String? {
        switch self {
        case .noPermission: "没有麦克风权限：系统设置 → 隐私与安全性 → 麦克风"
        case let .cannotStart(why): "麦克风没打开：\(why)"
        }
    }
}

@MainActor final class AudioRecorder: AudioRecording {
    private var recorder: AVAudioRecorder?
    private var url: URL?

    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    func start() async throws {
        guard await Self.micAuthorized() else { throw AudioRecordingError.noPermission }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bc-voice-\(UUID().uuidString).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else { throw AudioRecordingError.cannotStart("系统没让开始录音") }
            recorder = r; self.url = url
        } catch let e as AudioRecordingError {
            throw e
        } catch {
            throw AudioRecordingError.cannotStart(error.localizedDescription)
        }
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        defer { url = nil }
        return url
    }

    nonisolated private static func micAuthorized() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}
