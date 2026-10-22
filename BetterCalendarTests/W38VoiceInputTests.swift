//
//  W38VoiceInputTests.swift
//  BetterCalendarTests
//
//  W38：麦克风这一次用谁来听——Whisper 就绪用 Whisper；没就绪用苹果听写并写明原因（原则 10）；关着用苹果不加说明；
//  Whisper 失败直说、不偷偷改用苹果。全部用假引擎，不碰真麦克风 / 模型。
//

import Foundation
import Testing
@testable import BetterCalendar

@MainActor @Suite struct W38VoiceInputTests {
    final class FakeTranscriber: SpeechTranscribing {
        var state: TranscriberState
        var result: Result<String, Error> = .success("明天上午 9 点开 FDS 会议")
        var transcribed: [URL] = []
        init(_ state: TranscriberState) { self.state = state }
        func prepare() {}
        func transcribe(_ audio: URL) async throws -> String { transcribed.append(audio); return try result.get() }
        func setEnabled(_ on: Bool) {}
        var modelOnDisk: Bool { false }
        func deleteModel() async {}
    }

    final class FakeRecorder: AudioRecording {
        var started = 0
        var startError: Error?
        var file: URL?
        var elapsed: TimeInterval { 0 }
        func start() async throws {
            if let startError { throw startError }
            started += 1
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("w38-\(UUID().uuidString).wav")
            FileManager.default.createFile(atPath: url.path, contents: Data([0]))
            file = url
        }
        func stop() -> URL? { defer { file = nil }; return file }
    }

    final class FakeLive: LiveDictating {
        var state: SpeechDictation.State = .idle
        var isListening = false
        var onTranscript: (String) -> Void = { _ in }
        var toggles = 0
        func toggle() { toggles += 1; isListening.toggle(); state = isListening ? .listening : .idle }
        func stop() { isListening = false; state = .idle }
        func clearError() { if case .failed = state { state = .idle } }
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    @Test func readyWhisperRecordsThenTranscribesOnSecondTap() async throws {
        let t = FakeTranscriber(.ready), r = FakeRecorder(), live = FakeLive()
        let v = VoiceInput(transcriber: t, recorder: r, live: live)
        var heard: [String] = []
        v.onText = { heard.append($0) }
        v.tap(); await settle()
        #expect(v.phase == .recording && r.started == 1 && live.toggles == 0)
        #expect(v.statusLine == "正在听…再点一下麦克风结束")
        let file = try #require(r.file)
        v.tap(); await settle()
        #expect(v.phase == .idle && heard == ["明天上午 9 点开 FDS 会议"] && t.transcribed == [file])
        #expect(!FileManager.default.fileExists(atPath: file.path))   // 录音转完即删
        #expect(v.statusLine == nil)
    }

    @Test func notReadyWhisperFallsBackToAppleAndSaysWhy() async {
        let t = FakeTranscriber(.downloading(0.42)), r = FakeRecorder(), live = FakeLive()
        let v = VoiceInput(transcriber: t, recorder: r, live: live)
        v.tap(); await settle()
        #expect(live.toggles == 1 && r.started == 0)
        #expect(v.statusLine == "正在听（这次用苹果听写：Whisper 正在下载模型 42%）…再点一下结束")
        v.tap()   // 再点 = 结束苹果听写
        #expect(!live.isListening && v.statusLine == nil)
    }

    @Test func whisperOffUsesAppleWithoutAFallbackNote() async {
        let v = VoiceInput(transcriber: FakeTranscriber(.off), recorder: FakeRecorder(), live: FakeLive())
        v.tap(); await settle()
        #expect(v.fallbackReason == nil && v.statusLine == "正在听…再点一下麦克风结束")
        let noEngine = VoiceInput(transcriber: nil, recorder: FakeRecorder(), live: FakeLive())
        noEngine.tap(); await settle()
        #expect(noEngine.fallbackReason == nil)
    }

    @Test func whisperFailureIsSaidAndNotRetriedWithApple() async {
        let t = FakeTranscriber(.ready), live = FakeLive()
        t.result = .failure(WhisperTranscriberError.empty)
        let v = VoiceInput(transcriber: t, recorder: FakeRecorder(), live: live)
        var heard: [String] = []
        v.onText = { heard.append($0) }
        v.tap(); await settle()
        v.tap(); await settle()
        #expect(heard.isEmpty && live.toggles == 0)
        #expect(v.statusLine == "Whisper 没转出来：没听到能转成字的内容")
        v.tap(); await settle()   // 下一次点：说明清掉，重新开始录
        #expect(v.phase == .recording && v.statusLine == "正在听…再点一下麦克风结束")
    }

    @Test func micWithoutPermissionSaysSo() async {
        let r = FakeRecorder()
        r.startError = AudioRecordingError.noPermission
        let v = VoiceInput(transcriber: FakeTranscriber(.ready), recorder: r, live: FakeLive())
        v.tap(); await settle()
        #expect(v.phase == .idle && v.statusLine == "没有麦克风权限：系统设置 → 隐私与安全性 → 麦克风")
    }

    @Test func cancelDropsAHalfRecording() async throws {
        let t = FakeTranscriber(.ready), r = FakeRecorder()
        let v = VoiceInput(transcriber: t, recorder: r, live: FakeLive())
        v.tap(); await settle()
        let file = try #require(r.file)
        v.cancel()
        #expect(v.phase == .idle && t.transcribed.isEmpty && !FileManager.default.fileExists(atPath: file.path))
    }

    @Test func autoStopsAtTheLengthCap() async throws {
        let t = FakeTranscriber(.ready)
        let v = VoiceInput(transcriber: t, recorder: FakeRecorder(), live: FakeLive(), maxSeconds: 0.05)
        var heard: [String] = []
        v.onText = { heard.append($0) }
        v.tap(); await settle()
        try await Task.sleep(for: .milliseconds(300)); await settle()
        #expect(heard.count == 1 && v.phase == .idle)
    }

    @Test func whisperOutputIsSimplifiedAndTrimmed() {
        #expect(SpeechText.clean(" 今天有點累，改成散步半個小時 ") == "今天有点累，改成散步半个小时")
        #expect(SpeechText.clean("<|zh|>周末 Saturday 不排<|endoftext|>") == "周末 Saturday 不排")
    }

    @Test func stateLabelsSayWhatIsHappening() {
        #expect(TranscriberState.waitingForWiFi.label == "等连上 Wi-Fi 再下载模型（约 630 MB）")
        #expect(TranscriberState.downloading(0.995).label == "正在下载模型 100%")
        #expect(!TranscriberState.preparing.isReady && TranscriberState.ready.isReady)
    }

    @Test func whisperSwitchSyncsAcrossDevicesAndIsANewFeature() {
        #expect(SettingsSync.syncedKeys.contains(WhisperSettings.enabledKey))
        let d = UserDefaults(suiteName: "w38-\(UUID().uuidString)")!
        #expect(ExperimentDefaults.newFeature(WhisperSettings.enabledKey, in: d, channel: .daily) == false)   // 日用版默认关
        #expect(ExperimentDefaults.newFeature(WhisperSettings.enabledKey, in: d, channel: .dev) == true)
    }
}
