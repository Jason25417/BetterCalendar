//
//  ScreenTimeBlocking.swift
//  BetterCalendar
//
//  番茄钟绝对专注（SPEC §5.5，Family Controls entitlement 2026-07-11 获批）：
//  番茄**工作段**期间屏蔽用户自选的分心 App/类别/网站；休息段、手动休息、会话结束/取消/换计时一律解除。
//  自主支持式红线（原则 5）：默认关、名单用户自己在系统 FamilyActivityPicker 里选、随时可关可解除；
//  框架回传的任何使用数据不采集不上传（也没有采集的代码路径）。
//  屏蔽状态与聪音桥同一哲学：**幂等收敛**——挂在 persistRunState 必经点上，任何状态变更后把
//  屏蔽收敛到「工作段=屏蔽，其余=解除」，不依赖任何单个事件边沿。
//  ⚠️ 仅 iOS：FamilyControls 授权与 picker 在 macOS 沙盒下运行时失败（SPEC §8 已核实）。
//

#if os(iOS)
import Foundation
import FamilyControls
import ManagedSettings

enum ScreenTimeBlockingSettings {
    /// 总开关（默认关）。
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "focus.screenTimeShield") }
        set { UserDefaults.standard.set(newValue, forKey: "focus.screenTimeShield") }
    }

    /// 屏蔽模式（0.35.0，TestFlight 反馈#2 Jason 提）：
    /// blocklist=只屏蔽选中的（原行为，默认）；allowlist=**默认全屏蔽，选中的才放行**（绝对专注）。
    enum Mode: String { case blocklist, allowlist }
    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "focus.screenTimeShieldMode") ?? "") ?? .blocklist }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "focus.screenTimeShieldMode") }
    }

    /// 用户在 FamilyActivityPicker 选的屏蔽对象（App/类别/网站 token，系统不透明令牌，本地持久）。
    static var selection: FamilyActivitySelection {
        get {
            guard let data = UserDefaults.standard.data(forKey: "focus.screenTimeSelection"),
                  let sel = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
            else { return FamilyActivitySelection() }
            return sel
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "focus.screenTimeSelection")
            }
        }
    }

    static var selectionSummary: String {
        let s = selection
        let parts = [(s.applicationTokens.count, "个 App"), (s.categoryTokens.count, "个类别"),
                     (s.webDomainTokens.count, "个网站")].filter { $0.0 > 0 }
        return parts.isEmpty ? "还没选" : parts.map { "\($0.0) \($0.1)" }.joined(separator: "、")
    }
}

/// 屏蔽执行器：幂等 sync。ManagedSettingsStore 跨进程持久——App 崩溃/被杀屏蔽会残留，
/// 所以 VM init 也要 sync 一次（首个 sync 无条件应用，收敛掉任何残留）。
final class ScreenTimeBlocker {
    static let shared = ScreenTimeBlocker()
    private let store = ManagedSettingsStore(named: .init("pomodoroFocus"))
    private var shielding: Bool?   // nil=未知（启动态）：首次 sync 无条件应用

    var isAuthorized: Bool { AuthorizationCenter.shared.authorizationStatus == .approved }

    /// 请求「屏幕使用时间」个人授权（系统弹窗；模拟器上会失败，需真机）。
    func requestAuthorization() async -> Bool {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            DevLog.shared.info("屏蔽", "屏幕使用时间授权通过")
            return true
        } catch {
            DevLog.shared.warn("屏蔽", "屏幕使用时间授权失败/被拒：\(error.localizedDescription)")
            return false
        }
    }

    /// 把屏蔽收敛到目标状态（开关关/未授权一律=解除）。幂等：状态没变不动系统设置。
    func sync(shouldShield: Bool) {
        let want = shouldShield && ScreenTimeBlockingSettings.enabled && isAuthorized
        guard want != shielding else { return }
        shielding = want
        if want {
            let sel = ScreenTimeBlockingSettings.selection
            switch ScreenTimeBlockingSettings.mode {
            case .blocklist:   // 黑名单：只屏蔽选中的
                store.shield.applications = sel.applicationTokens.isEmpty ? nil : sel.applicationTokens
                store.shield.applicationCategories = sel.categoryTokens.isEmpty ? nil : .specific(sel.categoryTokens)
                store.shield.webDomains = sel.webDomainTokens.isEmpty ? nil : sel.webDomainTokens
            case .allowlist:   // 白名单：默认全屏蔽，选中的才放行
                store.shield.applications = nil
                store.shield.applicationCategories = .all(except: sel.applicationTokens)
                store.shield.webDomainCategories = .all(except: sel.webDomainTokens)
            }
            DevLog.shared.info("屏蔽", "番茄工作段 → 屏蔽生效（\(ScreenTimeBlockingSettings.mode == .allowlist ? "白名单：全屏蔽，放行 " : "")\(ScreenTimeBlockingSettings.selectionSummary)）")
        } else {
            store.clearAllSettings()
            DevLog.shared.info("屏蔽", "屏蔽解除")
        }
    }

    /// 模式/名单变了 → 下次 sync 重新应用（shielding 缓存作废）。
    func invalidate() { shielding = nil }

    /// 兜底立即解除（设置页按钮/总开关关掉时调）。
    func liftNow() {
        shielding = false
        store.clearAllSettings()
        DevLog.shared.info("屏蔽", "屏蔽手动解除")
    }
}
#endif
