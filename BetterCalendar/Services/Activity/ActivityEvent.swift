//
//  ActivityEvent.swift
//  BetterCalendar
//
//  SPEC §19 W13/W14 共用契约（2026-10-18，Jason：实验期数据源尽量宽，之后按使用日志删减）：
//  设备活动记录 = 被动信号的统一格式。W13 负责采集（Mac 前台 App/浏览器/空闲/锁屏，iPhone 快捷指令自动化的
//  App 打开/关闭，浏览器历史回填），W14 的哨兵读它判断要不要叫醒智能体。
//  只追加、不改写；来源与观察时刻写清楚（区分事实与推断）。App/网站名永不进复盘与留底（羞辱铁律）。
//

import Foundation

nonisolated struct ActivityEvent: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        /// Mac：前台 App 切换（appName/bundleID 有值）。
        case appActivated
        /// iPhone / iPad：快捷指令自动化报告的 App 打开 / 关闭。
        case appOpened, appClosed
        /// 浏览器当前页（url/pageTitle 有值）；回填的历史记录也用它，source 标 history。
        case browserPage
        /// 无键鼠输入开始 / 结束（Mac）。
        case idleStart, idleEnd
        case screenLocked, screenUnlocked
        case systemSleep, systemWake
        /// W13 新增：同一个 App 里前台窗口标题变了（windowTitle 有值；需要 Mac「辅助功能」权限）。
        case windowChanged
        /// 其他信号的扩展口（detail 里写清楚是什么）。W13 用到的 detail["signal"]：
        /// recorder（started/paused/resumed/stopped，标出记录覆盖的起止，空白≠没做事）、power、network、motion、sleep、workout、session。
        case other
    }

    /// 这条记录怎么来的：实时观察 / 事后回填（浏览器历史等）/ 快捷指令自动化。
    enum Source: String, Codable, Sendable { case live, history, shortcut }

    var id = UUID()
    /// 事情发生的时刻（回填记录 = 历史里记的时刻，不是读到的时刻）。
    var at: Date
    var kind: Kind
    var source: Source = .live
    /// 设备 id（ProposalDevice.id）与平台（"macOS" / "iOS"；iPad 也是 "iOS"，分 iPhone / iPad 看 deviceKind）。
    var deviceId: String
    var platform: String
    var appName: String? = nil
    var bundleID: String? = nil
    var url: String? = nil
    var pageTitle: String? = nil
    var windowTitle: String? = nil
    var detail: [String: String]? = nil
    /// W28：设备类别（ActivityDeviceKind.rawValue：mac / iphone / ipad）。可选字段 = 向后兼容：
    /// 旧记录（W28 之前）没有它；JSON 里缺省就不写，老版本解码时忽略多出的键。读的时候一律走 resolvedDeviceKind。
    var deviceKind: String? = nil

    /// 设备类别：有记录就用记录的；没有（W28 之前的旧记录）→ macOS = Mac，iOS = iPhone（那时只有 iPhone 一台 iOS 设备），inferred = true。
    var resolvedDeviceKind: (kind: ActivityDeviceKind, inferred: Bool) {
        if let raw = deviceKind, let k = ActivityDeviceKind(rawValue: raw) { return (k, false) }
        return (platform == "macOS" ? .mac : .iphone, platform != "macOS")
    }
}

/// W28：设备类别（iPad 加入后，「iOS」不再等于 iPhone）。
nonisolated enum ActivityDeviceKind: String, Codable, Sendable, CaseIterable {
    case mac, iphone, ipad

    var label: String {
        switch self { case .mac: "Mac"; case .iphone: "iPhone"; case .ipad: "iPad" }
    }

    /// 旧记录（没有 deviceKind）按 iPhone 计的说明——摘要 / 状态行里如实写出来。
    static let legacyNote = "W28 之前的 iOS 记录没有设备类别字段，按 iPhone 计（那时只有 iPhone 一台 iOS 设备）"

    /// 型号标识 → 类别（纯函数，可单测）：iPad* = iPad，其余 iOS 设备 = iPhone。模拟器的 hw.machine 是 arm64，
    /// 真实型号在环境变量 SIMULATOR_MODEL_IDENTIFIER 里。
    static func fromModelIdentifier(_ machine: String, simulatorModel: String? = nil) -> ActivityDeviceKind {
        let model = (simulatorModel?.isEmpty == false ? simulatorModel! : machine)
        return model.hasPrefix("iPad") ? .ipad : .iphone
    }

    /// 本机类别（进程内算一次；不碰主线程 API，快捷指令后台进程里也能用）。
    static let current: ActivityDeviceKind = {
        #if os(macOS)
        return .mac
        #else
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        let machine = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return fromModelIdentifier(machine, simulatorModel: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"])
        #endif
    }()
}

/// 活动记录存储：只追加；按时间窗读。实现由 W13 提供（Mac 本地按日文件），测试用内存版。
nonisolated protocol ActivityLog: Sendable {
    func append(_ events: [ActivityEvent]) async throws
    /// 时间窗内的记录，按 at 升序。
    func events(in window: DateInterval) async throws -> [ActivityEvent]
}

actor MemoryActivityLog: ActivityLog {
    private var rows: [ActivityEvent] = []
    init(_ rows: [ActivityEvent] = []) { self.rows = rows }
    func append(_ events: [ActivityEvent]) async throws { rows.append(contentsOf: events) }
    func events(in window: DateInterval) async throws -> [ActivityEvent] {
        rows.filter { window.contains($0.at) }.sorted { $0.at < $1.at }
    }
}
