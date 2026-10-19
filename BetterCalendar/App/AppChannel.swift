//
//  AppChannel.swift
//  BetterCalendar
//
//  W17（2026-10-19，Jason 定）：日用版 / Dev 版两个通道，同一台设备上并排安装、数据完全分开。
//  - 日用版（daily）= scheme「BetterCalendar」，TestFlight 分发，Jason 真实生活在用。
//  - Dev 版（dev）  = scheme「BetterCalendar Dev」（build configuration `Dev`，编译开关 `BC_DEV_CHANNEL`），
//    bundle `com.jason.BetterCalendar.dev`、显示名「BetterCalendar Dev」、本地开发签名安装。
//
//  会撞车的名字一律从这里取（唯一真相源）：iCloud 容器、App Group、钥匙串服务名、日历/提醒列表名、
//  Handoff 类型、本机数据档案目录、智能体桥接目录的通道标记。
//  按 bundle id 天然隔离、不用管的：UserDefaults.standard、App 沙盒容器（SwiftData 本地库、Application Support）、
//  iCloud 键值存储（ubiquity-kvstore-identifier = 团队前缀 + bundle id）、通知、App Intents。
//
//  iCloud：两个通道用同一个容器 `iCloud.com.jason.BetterCalendar`，但 Dev 版的 entitlements 写死
//  `com.apple.developer.icloud-container-environment = Development` → 读写的是 Development 环境，
//  与 TestFlight 日用版用的 Production 环境是两套完全独立的数据库。将来若 Dev 版也走 TestFlight，
//  Production 环境就会撞上 → 那时必须换独立容器（改 `cloudKitContainerID` + Dev entitlements，见交付报告）。
//

import Foundation

nonisolated enum AppChannel: String, CaseIterable, Sendable {
    case daily
    case dev

    /// 当前编译出来的是哪个通道（编译期决定，运行中不变）。
    static let current: AppChannel = {
        #if BC_DEV_CHANNEL
        return .dev
        #else
        return .daily
        #endif
    }()

    var isDev: Bool { self == .dev }

    /// 给人看的名字（日志、提示里用）。
    var displayName: String { self == .dev ? "BetterCalendar Dev" : "BetterCalendar" }

    /// iCloud 容器（见文件头：Dev 版靠 entitlements 钉在 Development 环境隔离）。
    var cloudKitContainerID: String { "iCloud.com.jason.BetterCalendar" }

    /// App Group（iOS：主 App ↔ 小组件/控制中心控件共享）。须与对应 entitlements 文件一致。
    var appGroupID: String { self == .dev ? "group.com.jason.BetterCalendar.dev" : "group.com.jason.BetterCalendar" }

    /// 钥匙串服务名（API key 等）。日用版保持历史值不变——改了就读不到已存的 key。
    var keychainService: String { self == .dev ? "com.jason.BetterCalendar.dev" : "com.jason.BetterCalendar" }

    /// 已冻结的 StateBridge 凭据服务名（Dev 版不碰日用版的 StateBridge 账户）。
    var stateBridgeKeychainService: String { keychainService + ".StateBridge" }

    /// Handoff 活动类型。须与 Info.plist 的 NSUserActivityTypes（`$(PRODUCT_BUNDLE_IDENTIFIER).handoff`）一致。
    var handoffActivityType: String { (self == .dev ? "com.jason.BetterCalendar.dev" : "com.jason.BetterCalendar") + ".handoff" }

    /// 本机数据档案 / 开发修改入口所在目录名（Mac 在「下载」下，iPhone 在 App 的「文稿」下）。
    var dataFolderName: String { self == .dev ? "BetterCalendar-Dev-Data" : "BetterCalendar-Data" }

    /// BetterCalendar 自建日历 / 提醒列表的名字。label = 「计划」「实际」「预览」「要紧事」。
    /// 日用版沿用历史名字「BetterCalendar · 计划 (Dev)」：已有日历按名字认领，改名 = 认不出旧日历、另建一本（不改）。
    /// Dev 版 =「BetterCalendar Dev · 计划」，一眼可辨、可整本删。
    func calendarTitle(_ label: String) -> String {
        switch self {
        case .daily: "BetterCalendar · \(label) (Dev)"
        case .dev: "BetterCalendar Dev · \(label)"
        }
    }

    /// 提醒事项里 BetterCalendar 那本列表。
    var remindersListTitle: String { calendarTitle("要紧事") }

    /// 其它通道（同一台设备上并排装的另一个 BetterCalendar）。
    var siblings: [AppChannel] { Self.allCases.filter { $0 != self } }

    /// 另一个通道的自建日历名：读「你的日历」时整本跳过——Dev 版的测试块不能被日用版当成你的安排，反之亦然。
    func siblingCalendarTitles(_ labels: [String]) -> Set<String> {
        Set(siblings.flatMap { s in labels.map { s.calendarTitle($0) } })
    }

    // MARK: 智能体桥接目录的通道标记

    /// 桥接目录（智能体工作区的 bridge/）里的通道标记文件名，内容 = rawValue。
    /// Dev 智能体工作区由 scripts/dev-runtime/setup-dev-runtime.sh 写入 `dev`；日用工作区没有这个文件 = daily。
    static let bridgeMarkerFile = "CHANNEL"

    /// 这个桥接目录属于哪个通道（没有标记 = 日用版的历史目录）。读不出的标记按「不认识」返回 nil。
    static func bridgeChannel(of folder: URL) -> AppChannel? {
        let url = folder.appendingPathComponent(bridgeMarkerFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return .daily }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return AppChannel(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// 桥接目录与本 App 通道不符时的说明（nil = 相符，可以连）。
    func bridgeMismatch(_ folder: URL) -> String? {
        let found = Self.bridgeChannel(of: folder)
        guard found != self else { return nil }
        let what = found.map { $0 == .dev ? "Dev 版智能体工作区" : "日用版智能体工作区" } ?? "通道标记读不出的目录"
        let want = self == .dev
            ? "BetterCalendar_AgentRuntime-dev/bridge（含 CHANNEL=dev）"
            : "BetterCalendar_AgentRuntime/bridge"
        return "这是\(what)的 bridge，\(displayName) 不能连（两套数据不能混）。请选 \(want)"
    }
}
