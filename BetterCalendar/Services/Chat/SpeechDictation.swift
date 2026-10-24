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
    /// 0.74.1：端侧识别一停顿就从头开新的一段——把说完的段攒起来，不让后一段盖掉前一段（Jason：开头说的句子经常被吞）。
    private var segments = DictationSegments()
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
        state = .starting; transcript = ""; segments = DictationSegments()
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
        task = recognizer.recognitionTask(with: req, resultHandler: Self.handler { [weak self] text, isFinal, segmentEnded, error in
            guard let self else { return }
            if let text {
                self.transcript = self.segments.receive(text, segmentEnded: segmentEnded)
                self.onTranscript(self.transcript)
            }
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

    nonisolated private static func handler(_ update: @escaping @MainActor (String?, Bool, Bool, Error?) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            // 系统标出「这一段说完了」（带段落元数据）——下一个结果会从头开始
            let segmentEnded = result?.speechRecognitionMetadata != nil
            let message = error.map { $0 as NSError }
            Task { @MainActor in update(text, isFinal, segmentEnded, message) }
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

/// 0.74.1：把识别结果按段攒起来（纯逻辑，可单测）。端侧识别停顿后会从头开一段，每个结果只含「当前这段」：
/// ① 结果带段落元数据 = 这段说完了 → 存起来；② 新结果明显不是上一段的延续（开头对不上且更短）→ 上一段已说完，先存起来。
nonisolated struct DictationSegments: Equatable, Sendable {
    private(set) var committed = ""
    private var current = ""

    /// 收到一个识别结果，返回到目前为止的全文。
    mutating func receive(_ text: String, segmentEnded: Bool) -> String {
        let squeezed = Self.squeeze(text)
        if current.isEmpty, !squeezed.isEmpty, Self.squeeze(committed).hasSuffix(squeezed) { return full }   // 段尾结果重复送达
        // 有的系统版本最后一个结果是整段全文（含已存的段）→ 以它为准，别重复拼
        if Self.squeeze(committed).count >= 4, squeezed.hasPrefix(Self.squeeze(committed)) { committed = ""; current = text; return finish(segmentEnded) }
        if !current.isEmpty, !Self.continues(text, from: current) { commit(current) }
        current = text
        return finish(segmentEnded)
    }

    private mutating func finish(_ segmentEnded: Bool) -> String {
        if segmentEnded { commit(current); current = "" }
        return full
    }

    private static func squeeze(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    var full: String { Self.join(committed, current) }

    private mutating func commit(_ segment: String) {
        guard !segment.isEmpty else { return }
        committed = Self.join(committed, segment)
    }

    /// 同一段的修订：开头两个字一样，或者变长了（识别边听边改，开头基本不动）。
    static func continues(_ new: String, from old: String) -> Bool {
        new.hasPrefix(String(old.prefix(2))) || new.count >= old.count
    }

    /// 中文直接接；两边都是西文字母 / 数字时中间加空格。
    static func join(_ a: String, _ b: String) -> String {
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        let ascii: (Character?) -> Bool = { c in c.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false }
        return a + (ascii(a.last) && ascii(b.first) ? " " : "") + b
    }
}
