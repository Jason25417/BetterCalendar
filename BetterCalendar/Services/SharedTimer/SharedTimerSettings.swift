//
//  SharedTimerSettings.swift
//  BetterCalendar
//
//  W5：共享计时后端开关。W8（Jason 2026-10-18）：从没设过 = 开（iCloud）；手动关过的保留。
//  开关随设置同步（两端用同一个后端才看得到彼此的计时），每台设备仍在下次启动时各自过下面的闸门。
//  - 开关只在 App 启动时生效：一次运行只用一个后端，绝不双写、不混读。
//  - 切换闸门：当前通道还有非测试的进行中计时或未发送命令时拒绝切换（启动时再查一遍旧本机文件）。
//  设计见 docs/bc-shared-timer-icloud.md §7。
//

import Foundation
import Observation

@MainActor enum SharedTimerSettings {
    static let key = "sharedTimer.icloud.enabled"

    static let defaultRequested = true
    static func requested(_ defaults: UserDefaults = .standard) -> Bool { ExperimentDefaults.bool(key, default: defaultRequested, in: defaults) }
    static func setRequested(_ value: Bool, _ defaults: UserDefaults = .standard) { defaults.set(value, forKey: key) }

    /// 启动决定：开关关 → 旧通道；开关开但旧通道还有进行中计时/待发命令（或旧文件读不出）→ 推迟，仍用旧通道。
    static func launchDecision(requested: Bool, legacy: () throws -> BridgeTaskLocalFile) -> (backend: SharedTimerBackend, note: String?) {
        guard requested else { return (.stateBridge, nil) }
        let file: BridgeTaskLocalFile
        do { file = try legacy() } catch {
            return (.stateBridge, "旧通道本机计时队列读取失败，暂不切换到 iCloud（原文件已保留）")
        }
        if let blocker = blocker(sessions: file.state?.sessions ?? [],
                                 pending: file.pending.filter { !$0.needsReview }.count, from: .stateBridge) {
            return (.stateBridge, blocker + "；本次启动继续用旧通道")
        }
        return (.icloud, nil)
    }

    /// 切换闸门（纯函数）：测试计时不阻挡；被拒待复核的旧命令不阻挡（它们不会再发送）。
    static func blocker(sessions: [BridgeTaskSession], pending: Int, from backend: SharedTimerBackend) -> String? {
        if let running = sessions.first(where: { !$0.isExperiment && $0.status != .finished }) {
            return "\(backend.label)里还有正在计时的「\(running.title)」，先结束它再切换（记录保留在原处）"
        }
        if pending > 0 { return "\(backend.label)还有 \(pending) 条计时操作待同步，同步完成后再切换" }
        return nil
    }
}

/// 开发期面板用的开关控制器：显示当前后端、记录「下次启动生效」的请求、执行切换闸门。
@MainActor @Observable final class SharedTimerBackendControl {
    /// 设置页没有直接拿组装点依赖的通道，开发期面板经这里找到当前实例（同 ExecutionBridge.shared 模式）。
    static weak var current: SharedTimerBackendControl?

    let active: SharedTimerBackend
    private(set) var requested: Bool
    private(set) var notice: String?
    @ObservationIgnored weak var tasks: BridgeTaskViewModel?
    @ObservationIgnored private let defaults: UserDefaults

    init(active: SharedTimerBackend, launchNote: String?, defaults: UserDefaults = .standard) {
        self.active = active; self.defaults = defaults
        self.requested = SharedTimerSettings.requested(defaults)
        self.notice = launchNote
    }

    var restartPending: Bool { requested != (active == .icloud) }

    func setRequested(_ on: Bool) {
        guard on != requested else { return }
        // 改回当前正在用的后端 = 撤销未生效的请求，总是允许；真正要换后端时才过闸门。
        if on != (active == .icloud), let tasks,
           let blocker = SharedTimerSettings.blocker(sessions: tasks.sessions, pending: tasks.pendingCount, from: active) {
            notice = blocker
            if !TestHost.isActive { DevLog.shared.warn("共享计时", "切换未执行：\(blocker)") }
            return
        }
        SharedTimerSettings.setRequested(on, defaults)
        requested = on
        notice = restartPending ? "已设定，重启 App 后生效（计时将记在：\(on ? SharedTimerBackend.icloud.label : SharedTimerBackend.stateBridge.label)）" : nil
        if !TestHost.isActive { DevLog.shared.info("共享计时", "后端请求 → \(on ? "iCloud" : "旧通道")（下次启动生效）") }
    }
}
