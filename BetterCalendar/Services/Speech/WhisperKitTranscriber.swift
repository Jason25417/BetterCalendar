//
//  WhisperKitTranscriber.swift
//  BetterCalendar
//
//  W38：端侧 Whisper（WhisperKit，模型 large-v3-v20240930_626MB = OpenAI large-v3-turbo 压缩版）。
//  · 选型依据（10-22 Mac 实测 Jason 本人 10 句）：错误率 12.4%（1.6 GB 原版 11.4%、547 MB 14.4%），10 秒内的话约 1 秒出字；
//    语言固定中文（App 内自动识别会把中英混说的句子认成日语，10-22 实测；固定中文时英文句子照样出英文）；词表提示反而会把提示词塞进结果 → 不用。
//  · 模型放 App Support/BetterCalendar/WhisperModels（不进 iCloud、不进备份以外的地方）；昂贵网络（蜂窝 / 热点）不下，写明「等 Wi-Fi」。
//  · 这台设备第一次加载要编译（Mac 实测 40–100 秒），下完立刻在后台做掉；之后加载 < 2 秒。iPhone 上闲置 3 分钟卸载，省内存。
//  · WhisperKit 不是 Sendable → 只放在 WhisperEngine 这个 actor 里用，跨界只传字符串 / URL / 进度。
//

import Foundation
import Network
import WhisperKit

nonisolated enum WhisperSettings {
    static let enabledKey = "voice.whisper.enabled"
    static let model = "large-v3-v20240930_626MB"
    /// W17 新功能约定：键不存在 → Dev 版开、日用版关；随设置同步。
    static var enabled: Bool {
        get { ExperimentDefaults.newFeature(enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    static var modelRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterCalendar/WhisperModels", isDirectory: true)
    }
}

@MainActor @Observable final class WhisperKitTranscriber: SpeechTranscribing {
    private(set) var state: TranscriberState = .off
    private let engine = WhisperEngine()
    private var preparing: Task<Void, Never>?
    private var idleUnload: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var syncObserver: NSObjectProtocol?

    init() {
        // 另一台设备改了开关（iCloud 设置同步）→ 这台跟着开 / 关
        let hop = Self.onMain { [weak self] in self?.prepare() }
        syncObserver = NotificationCenter.default.addObserver(forName: SettingsSync.didSyncRemotely, object: nil, queue: .main) { _ in hop() }
    }

    /// 设置页的开关。
    func setEnabled(_ on: Bool) {
        WhisperSettings.enabled = on
        prepare()
    }

    func prepare() {
        guard !TestHost.isActive else { return }
        guard WhisperSettings.enabled else {
            preparing?.cancel(); preparing = nil
            stopWatchingNetwork()
            state = .off
            Task { await engine.unload() }
            return
        }
        switch state {
        case .ready, .downloading, .preparing: return
        case .off, .waitingForWiFi, .failed: break
        }
        guard preparing == nil else { return }
        preparing = Task { [weak self] in
            await self?.run()
            self?.preparing = nil
        }
    }

    func transcribe(_ audio: URL) async throws -> String {
        guard state.isReady else { throw WhisperTranscriberError.notReady(state.label) }
        idleUnload?.cancel()
        defer { scheduleIdleUnload() }
        let started = Date()
        let raw = try await engine.transcribe(audio.path)
        let text = SpeechText.clean(raw)
        DevLog.shared.info("语音输入", "Whisper 转写 \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒，\(text.count) 字")
        return text
    }

    var modelOnDisk: Bool { WhisperEngine.downloadedFolder() != nil }

    /// 删掉这台设备上下载的模型（设置页按钮）。开关不变；开着的话下次会重新下载。
    func deleteModel() async {
        preparing?.cancel(); preparing = nil
        await engine.unload()
        try? FileManager.default.removeItem(at: WhisperSettings.modelRoot)
        state = WhisperSettings.enabled ? .failed("模型已删除，重新打开开关会再下载") : .off
    }

    // MARK: 准备

    private func run() async {
        let folder: URL
        if let local = WhisperEngine.downloadedFolder() {
            folder = local
        } else {
            guard await !Self.onExpensiveNetwork() else {
                state = .waitingForWiFi
                watchNetwork()
                return
            }
            state = .downloading(0)
            do {
                folder = try await WhisperEngine.download(progress: Self.onMain { [weak self] (p: Double) in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(p)
                })
            } catch {
                return fail("模型没下载下来：\(error.localizedDescription)")
            }
        }
        state = .preparing
        let started = Date()
        do {
            try await engine.load(folder: folder)
        } catch {
            return fail("模型没加载起来：\(error.localizedDescription)")
        }
        guard WhisperSettings.enabled else { await engine.unload(); state = .off; return }
        DevLog.shared.info("语音输入", "Whisper 模型就绪（加载 \(Int(Date().timeIntervalSince(started))) 秒）")
        state = .ready
        stopWatchingNetwork()
        scheduleIdleUnload()
    }

    private func fail(_ why: String) {
        state = .failed(why)
        DevLog.shared.warn("语音输入", why)
    }

    /// iPhone / iPad：闲置 3 分钟卸载（下次用时重新加载，编译好的缓存还在，约 2 秒）。Mac 常驻。
    private func scheduleIdleUnload() {
        #if os(iOS)
        idleUnload?.cancel()
        idleUnload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, let self else { return }
            await self.engine.unloadKeepingFolder()
        }
        #endif
    }

    // MARK: 网络（昂贵网络不下载）

    nonisolated private static func onExpensiveNetwork() async -> Bool {
        await withCheckedContinuation { c in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                c.resume(returning: path.isExpensive || path.status != .satisfied)
            }
            monitor.start(queue: DispatchQueue(label: "bc.whisper.netcheck"))
        }
    }

    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = Self.onPath { [weak self] in
            guard let self, self.state == .waitingForWiFi else { return }
            self.prepare()
        }
        monitor.start(queue: DispatchQueue(label: "bc.whisper.netwatch"))
        pathMonitor = monitor
    }

    private func stopWatchingNetwork() { pathMonitor?.cancel(); pathMonitor = nil }

    // MARK: 不在主 actor 上的回调 → 跳回主线程

    nonisolated private static func onMain(_ f: @escaping @MainActor () -> Void) -> @Sendable () -> Void {
        { Task { @MainActor in f() } }
    }

    nonisolated private static func onMain(_ f: @escaping @MainActor (Double) -> Void) -> @Sendable (Double) -> Void {
        { v in Task { @MainActor in f(v) } }
    }

    nonisolated private static func onPath(_ resume: @escaping @MainActor () -> Void) -> @Sendable (NWPath) -> Void {
        { path in
            guard path.status == .satisfied, !path.isExpensive else { return }
            Task { @MainActor in resume() }
        }
    }
}

nonisolated enum WhisperTranscriberError: LocalizedError {
    case notReady(String)
    case empty
    var errorDescription: String? {
        switch self {
        case let .notReady(why): "语音模型还没准备好（\(why)）"
        case .empty: "没听到能转成字的内容"
        }
    }
}

/// 只有这个 actor 碰 WhisperKit（它不是 Sendable）。
actor WhisperEngine {
    private var kit: WhisperKit?
    private var folder: URL?

    /// 已经下好的模型目录（有就不再下载）。
    nonisolated static func downloadedFolder() -> URL? {
        let dir = WhisperSettings.modelRoot.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(WhisperSettings.model)")
        let needed = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        return needed.allSatisfy({ FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }) ? dir : nil
    }

    nonisolated static func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: WhisperSettings.modelRoot, withIntermediateDirectories: true)
        return try await WhisperKit.download(variant: WhisperSettings.model, downloadBase: WhisperSettings.modelRoot) { p in
            progress(p.fractionCompleted)
        }
    }

    func load(folder: URL) async throws {
        if kit != nil, self.folder == folder { return }
        let config = WhisperKitConfig(model: WhisperSettings.model, downloadBase: WhisperSettings.modelRoot, modelFolder: folder.path,
                                      verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
        kit = try await WhisperKit(config)
        self.folder = folder
    }

    func transcribe(_ path: String) async throws -> String {
        if kit == nil, let folder { try await load(folder: folder) }
        guard let kit else { throw WhisperTranscriberError.notReady("模型没加载") }
        // 与 10-22 实测（whisperkit-cli）同一套解码参数：固定中文（自动识别会把中英混说认成日语）；不加提示词（会把提示词塞进结果）；
        // 不设首字置信度门槛（库默认 -1.5 会把开头没把握的整句丢掉，第 5 句「下周三…」就被吞成空）；VAD 切段（长录音也稳）
        let options = DecodingOptions(task: .transcribe, language: "zh", usePrefillPrompt: true, detectLanguage: false,
                                      skipSpecialTokens: true, firstTokenLogProbThreshold: nil, chunkingStrategy: .vad)
        let results = try await kit.transcribe(audioPath: path, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WhisperTranscriberError.empty }
        return text
    }

    /// 卸载但记住目录（iPhone 闲置省内存，下次用时自动重新加载）。
    func unloadKeepingFolder() async {
        await kit?.unloadModels()
        kit = nil
    }

    func unload() async {
        await unloadKeepingFolder()
        folder = nil
    }
}
