//
//  SpeechDictation.swift
//  BetterCalendar
//
//  W36（Jason 2026-10-22）：输入框的语音输入——点一下开始听、边说边出字、再点一下结束；字落进输入框，可以改了再发。
//  系统语音识别（SFSpeechRecognizer，普通话；设备支持就只在本机识别）。只在你按下时录音；没有权限 / 识别失败 = 原因写在输入框旁（不静默）。
//  音频回调在音频线程：回调由 nonisolated 工厂函数创建，再跳回主线程更新状态（Swift 6 默认主 actor 隔离下，闭包在别的线程被调用会崩）。
//

import AVFoundation
import Foundation
import Speech

@MainActor @Observable final class SpeechDictation {
    enum State: Equatable { case idle, starting, listening, failed(String) }
    private(set) var state: State = .idle
    /// 这一轮听到的字（边说边更新）。
    private(set) var transcript = ""
    /// 每次识别结果更新时（组装：把字写进输入框）。
    var onTranscript: (String) -> Void = { _ in }

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isListening: Bool { state == .listening || state == .starting }

    func toggle() {
        if isListening { stop() } else { Task { await start() } }
    }

    func start() async {
        guard !TestHost.isActive, !isListening else { return }
        state = .starting; transcript = ""
        guard await Self.speechAuthorized() else { return fail("没有语音识别权限：系统设置 → 隐私与安全性 → 语音识别") }
        guard await Self.micAuthorized() else { return fail("没有麦克风权限：系统设置 → 隐私与安全性 → 麦克风") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
            return fail("语音识别现在用不了（可能没联网，且这台设备不支持本机识别）")
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let engine = AVAudioEngine()
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(req))
            engine.prepare()
            try engine.start()
        } catch {
            return fail("麦克风没打开：\(error.localizedDescription)")
        }
        self.engine = engine; self.request = req
        task = recognizer.recognitionTask(with: req, resultHandler: Self.handler { [weak self] text, isFinal, error in
            guard let self else { return }
            if let text { self.transcript = text; self.onTranscript(text) }
            if let error, self.state == .listening, self.transcript.isEmpty {
                self.fail("没听清：\(error.localizedDescription)")
            } else if isFinal || error != nil {
                self.teardown(); self.state = .idle
            }
        })
        state = .listening
    }

    /// 结束：停止录音，等最后一段结果回来（handler 里收尾）。
    func stop() {
        guard isListening else { return }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        state = .idle
    }

    func clearError() { if case .failed = state { state = .idle } }

    private func fail(_ why: String) {
        teardown()
        state = .failed(why)
        DevLog.shared.warn("语音输入", why)
    }

    private func teardown() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        engine = nil; request = nil; task = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: 不在主 actor 上的回调

    nonisolated private static func tap(_ req: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in req.append(buffer) }
    }

    nonisolated private static func handler(_ update: @escaping @MainActor (String?, Bool, Error?) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message = error.map { $0 as NSError }
            Task { @MainActor in update(text, isFinal, message) }
        }
    }

    nonisolated private static func speechAuthorized() async -> Bool {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    nonisolated private static func micAuthorized() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}
