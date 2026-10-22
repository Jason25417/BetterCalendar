//
//  SpeechTranscribing.swift
//  BetterCalendar
//
//  W38（Jason 2026-10-22）：输入框的语音换成端侧 Whisper——点一下开始录、再点一下停，整段转成字（约 1 秒），落进输入框改了再发。
//  · 上层（VoiceInput）只认这几个协议：SpeechTranscribing（整段录音 → 字）、AudioRecording（录音）、LiveDictating（苹果听写，边说边出字）。
//  · 苹果听写是 Whisper 没准备好时的兜底，**每次都写明原因**（原则 10：不冒充、不静默）；Whisper 转写失败就直说失败，不自动改用苹果重转。
//  · 开关「voice.whisper.enabled」随 iCloud 同步（属于人）；模型是设备类，每台各自下载 / 编译、进度各看各的。
//

import Foundation
import SwiftUI

/// 端侧转写引擎现在能不能用。
nonisolated enum TranscriberState: Equatable, Sendable {
    /// 开关关着（不下载、不占内存）
    case off
    /// 开了，但现在是昂贵网络（蜂窝 / 个人热点）：等连上 Wi-Fi 再下（约 630 MB）
    case waitingForWiFi
    /// 下载中（0…1）
    case downloading(Double)
    /// 下完了，正在加载 / 编译（这台设备第一次要 40–100 秒）
    case preparing
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }

    /// 给人看的一句（设置页、兜底说明共用）。
    var label: String {
        switch self {
        case .off: "没开"
        case .waitingForWiFi: "等连上 Wi-Fi 再下载模型（约 630 MB）"
        case let .downloading(p): "正在下载模型 \(Int((p * 100).rounded()))%"
        case .preparing: "正在准备模型（这台设备第一次要一两分钟）"
        case .ready: "已就绪"
        case let .failed(why): "出错了：\(why)"
        }
    }
}

/// 整段录音 → 字（端侧）。
@MainActor protocol SpeechTranscribing: AnyObject {
    var state: TranscriberState { get }
    /// 开关开着就开始准备（下载 + 加载；幂等）。
    func prepare()
    /// 转写一段录音；结果已转简体、去掉首尾空白。
    func transcribe(_ audio: URL) async throws -> String
    /// 设置页：开 / 关（随 iCloud 同步；开 = 这台开始准备，关 = 卸载）。
    func setEnabled(_ on: Bool)
    /// 这台设备上有没有已下载的模型。
    var modelOnDisk: Bool { get }
    /// 删掉这台设备上的模型（约 630 MB）。
    func deleteModel() async
}

/// 录一段话到文件（16 kHz 单声道）。
@MainActor protocol AudioRecording: AnyObject {
    /// 开始录音；没有麦克风权限 / 打不开 → 抛错（说明写在错误里）。
    func start() async throws
    /// 停止并交出文件。
    func stop() -> URL?
    /// 已录秒数。
    var elapsed: TimeInterval { get }
}

/// 苹果听写（边说边出字）。
@MainActor protocol LiveDictating: AnyObject {
    var state: SpeechDictation.State { get }
    var isListening: Bool { get }
    var onTranscript: (String) -> Void { get set }
    func toggle()
    func stop()
    func clearError()
}

extension SpeechDictation: LiveDictating {}

nonisolated enum SpeechText {
    /// Whisper 输出的收尾：繁体 → 简体（压缩模型有时出繁体，实测 10-22）、去首尾空白、去掉偶尔冒出的特殊标记。
    static func clean(_ raw: String) -> String {
        let noTokens = raw.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        let simplified = noTokens.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? noTokens
        return simplified.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension EnvironmentValues {
    /// 全 App 共用的一个端侧转写引擎（组装点注入；没注入 = 只用苹果听写）。
    @Entry var speechTranscriber: (any SpeechTranscribing)? = nil
}
