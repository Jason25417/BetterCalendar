//
//  DevWhisperSelfTest.swift
//  BetterCalendar
//
//  W38 自测（DEBUG only）：启动带 BC_DEV_WHISPER_FILES=<逗号分隔的录音路径>（放在 App 容器 tmp 里，沙盒读得到）→
//  等真的 WhisperKitTranscriber 下载 / 准备好，逐条转写，结果打印到 stdout（BC_DEV_WHISPER 开头）。不用人对着麦克风说话。
//

#if DEBUG
import Foundation

@MainActor enum DevWhisperSelfTest {
    static func runIfRequested(_ t: WhisperKitTranscriber?) {
        guard let t, let list = ProcessInfo.processInfo.environment["BC_DEV_WHISPER_FILES"], !list.isEmpty else { return }
        Task {
            let started = Date()
            var last = ""
            while !t.state.isReady {
                if case let .failed(why) = t.state { return print("BC_DEV_WHISPER 失败：\(why)") }
                if t.state.label != last { last = t.state.label; print("BC_DEV_WHISPER 状态 \(Int(Date().timeIntervalSince(started)))s：\(last)") }
                if Date().timeIntervalSince(started) > 900 { return print("BC_DEV_WHISPER 超时：\(t.state.label)") }
                try? await Task.sleep(for: .milliseconds(500))
            }
            print("BC_DEV_WHISPER 就绪，用时 \(Int(Date().timeIntervalSince(started)))s")
            for path in list.split(separator: ",").map(String.init) {
                // 直接调引擎（不经 VoiceInput），所以不会删原录音
                let s = Date()
                do {
                    let text = try await t.transcribe(URL(fileURLWithPath: path))
                    print(String(format: "BC_DEV_WHISPER %.2fs %@ :: %@", Date().timeIntervalSince(s), (path as NSString).lastPathComponent, text))
                } catch {
                    print("BC_DEV_WHISPER 出错 \((path as NSString).lastPathComponent)：\(error.localizedDescription)")
                }
            }
            print("BC_DEV_WHISPER 完")
        }
    }
}
#endif
