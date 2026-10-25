//
//  VoiceInput.swift
//  BetterCalendar
//
//  W38：麦克风按钮背后的那一层——这一次用谁来听：
//  · Whisper 开着且就绪 → 录一段，再点一下停 → 约 1 秒整段出字。
//  · Whisper 开着但没就绪（等 Wi-Fi / 下载中 / 准备中 / 出错）→ 这一次用苹果听写，并写明「这次用的是苹果听写：<原因>」（原则 10：不冒充）。
//  · Whisper 关着 → 苹果听写（这是你选的，不算兜底，不加说明）。
//  · Whisper 转写失败 → 直说失败，不偷偷改用苹果重转。
//  字落进输入框（接在你已经打的字后面），由你改了再发——不自动发送（原则 7）。
//

import Foundation

@MainActor @Observable final class VoiceInput {
    enum Phase: Equatable { case idle, recording, transcribing }
    private(set) var phase: Phase = .idle
    /// 这一次用苹果听写的原因（Whisper 没就绪时）；nil = 没在兜底。
    private(set) var fallbackReason: String?
    private(set) var failure: String?
    /// 听到的字（Whisper 一次整段；苹果边说边更新这一轮的全文）。
    var onText: (String) -> Void = { _ in }

    private let transcriber: (any SpeechTranscribing)?
    private let recorder: any AudioRecording
    private let live: any LiveDictating
    private let maxSeconds: TimeInterval
    private var autoStop: Task<Void, Never>?

    init(transcriber: (any SpeechTranscribing)?, recorder: any AudioRecording, live: any LiveDictating, maxSeconds: TimeInterval = 120) {
        self.transcriber = transcriber; self.recorder = recorder; self.live = live; self.maxSeconds = maxSeconds
        live.onTranscript = { [weak self] heard in self?.onText(heard) }
    }

    var isActive: Bool { phase != .idle || live.isListening }

    /// 输入框上方的一行（nil = 不占位）。
    var statusLine: String? {
        switch phase {
        case .recording: return "正在听…再点一下麦克风结束"
        case .transcribing: return "正在转成字…"
        case .idle: break
        }
        if case let .failed(why) = live.state { return why }
        if live.isListening {
            return fallbackReason.map { "正在听（这次用苹果听写：\($0)）…再点一下结束" } ?? "正在听…再点一下麦克风结束"
        }
        return failure
    }

    func tap() {
        switch phase {
        case .recording: Task { await finishRecording() }; return
        case .transcribing: return
        case .idle: break
        }
        if live.isListening { live.stop(); return }
        failure = nil; live.clearError()
        if let transcriber, transcriber.state.isReady {
            fallbackReason = nil
            Task { await startRecording() }
        } else {
            let state = transcriber?.state ?? .off
            fallbackReason = state == .off ? nil : "Whisper \(state.label)"
            if let reason = fallbackReason { DevLog.shared.info("语音输入", "这次用苹果听写：\(reason)") }
            live.toggle()
        }
    }

    /// 输入框消失时收尾（录了一半就丢掉，不转写）。
    func cancel() {
        autoStop?.cancel()
        if phase == .recording, let url = recorder.stop() { try? FileManager.default.removeItem(at: url) }
        if live.isListening { live.stop() }
        phase = .idle
    }

    private func startRecording() async {
        do {
            try await recorder.start()
        } catch {
            return fail(error.localizedDescription)
        }
        phase = .recording
        autoStop = Task { [weak self, maxSeconds] in
            try? await Task.sleep(for: .seconds(maxSeconds))
            guard !Task.isCancelled, let self, self.phase == .recording else { return }
            await self.finishRecording()
        }
    }

    private func finishRecording() async {
        autoStop?.cancel()
        guard phase == .recording, let url = recorder.stop() else { phase = .idle; return }
        phase = .transcribing
        defer { try? FileManager.default.removeItem(at: url); phase = .idle }
        guard let transcriber else { return fail("语音模型不在了") }
        do {
            let text = try await transcriber.transcribe(url)
            onText(text)
        } catch {
            fail("Whisper 没转出来：\(error.localizedDescription)")
        }
    }

    private func fail(_ why: String) {
        failure = why
        DevLog.shared.warn("语音输入", why)
    }
}
