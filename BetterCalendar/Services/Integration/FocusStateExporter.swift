//
//  FocusStateExporter.swift
//  BetterCalendar
//
//  聪音（《放松时光：与你共享 Lo-Fi 故事》）联动（Jason 2026-07-10，两侧哲学审核通过、见 SPEC §11 / 待讨论点子 #17）：
//  把当前专注状态写成 focus-state.json，供聪音的 BepInEx mod 读 → 驱动番茄/情绪/经验值。
//  单向 BC→聪音、本地文件桥（同 Mac、零云）。仅在设置开「聪音联动」时写；关掉即删文件（mod 见不到文件=不驱动）。
//  红线：落后=温柔陪着、完成=欢快，绝不失望——BC 只如实吐状态，聪音那边只放大做成。
//

import Foundation

enum FocusStateExporter {
    /// 测试 host 探测：CLI 单测与真 App 共享 UserDefaults/容器——测试绝不碰桥文件
    /// （否则联动开着时跑单测会把测试数据推给正在运行的游戏）。集中在此，所有读写口都过这道闸。
    private static var isTestHost: Bool { TestHost.isActive }   // 2026-07-21：原 XCTestCase 检测在 Swift Testing 下失效 → 统一到 [[TestHost]]

    /// 联动总开关（热切换）。关掉时顺手删掉状态文件——mod 靠文件在不在判断是否驱动。
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "integration.chiyneSync") }
        set {
            UserDefaults.standard.set(newValue, forKey: "integration.chiyneSync")
            if !newValue { try? fileURL.map { try FileManager.default.removeItem(at: $0) } }
        }
    }

    struct State: Codable {
        var schemaVersion = 1
        var updatedAt: Date
        var active: Active?           // 当前正在做的事（nil=空档）
        var lastEvent: Event?         // 最近一次事件（mod 据此触发起止语音/经验值）
        struct Active: Codable {
            var title: String
            var timingStyle: String   // light / pomodoro / none
            var startedAt: Date
            var elapsedSec: Int
            /// 累计不计投入的秒数（休息暂停等；含正在进行中的那段休息）——0.66 时间戳授时。
            /// 游戏侧可纯算术推：净投入 = now − startedAt − pausedSec，**无视轮询延迟与掉帧**。
            /// elapsedSec 保留作兼容兜底（老 mod 仍读它）。
            var pausedSec: Int?
            var plannedSec: Int?      // 计划时长（轻计时的预算；nil=计划外）
            // 终点对齐协议（Jason 2026-07-10 定）：BC 算好终点推给游戏、游戏按终点反推——
            // 休息暂停/接替等都被 BC 折进 endsAt，游戏零计算误差；tick 刷新时终点自动顺延。
            var endsAt: Date?             // 当前段/任务的预计结束时刻（轻计时=任务终点；番茄=当前段终点）
            var inRest: Bool?             // 番茄：当前是否休息段
            var segmentsRemaining: Int?   // 番茄：当前段之后还剩几个完整工作段；-1=不限段
            var workSec: Int?             // 番茄：工作段长（秒）
            var restSec: Int?             // 番茄：休息段长（秒）
        }
        struct Event: Codable {
            var kind: String          // start / complete / tick
            var title: String
            var durationSec: Int?     // complete 时=这件事投入时长（→换算经验值）
            // 事件账本（0.31.3，2 秒导出配套）：重要事件（start/complete）带单调 seq（epoch 毫秒），
            // tick 导出时**原样保留上一个重要事件**不覆盖——mod 按 seq 判「没见过才处理」（exactly-once），
            // 见过的只做状态对账。否则 2 秒一写会把事件冲掉、mod 两次轮询间漏结算。
            var seq: Int? = nil
        }
    }

    // MARK: 桥文件夹（0.28.3，TCC 修复）：macOS 的「其他 App 数据」保护会拦住游戏读 BC 沙盒容器——
    // 解法=用户在设置里**选一次**真实文件夹（推荐 ~/Library/Application Support/BetterCalendar），
    // security-scoped bookmark 持久授权：BC（沙盒）合法写、游戏（非沙盒）零 TCC 直读。容器路径作后备。

    #if os(macOS)
    private static let bookmarkKey = "integration.bridgeFolderBookmark"

    /// 当前桥文件夹路径（nil=未设置，走容器后备）。设置页显示用。
    static var bridgeFolderPath: String? { resolvedBridgeFolder()?.path }

    static func setBridgeFolder(_ url: URL) {
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            DevLog.shared.info("聪音", "桥文件夹已设为 \(url.path)（游戏可直读，无 TCC 阻拦）")
        } else {
            DevLog.shared.error("聪音", "桥文件夹书签创建失败：\(url.path)")
        }
    }

    private static func resolvedBridgeFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()   // 桥是长期通道：App 存续期保持访问（简化不配对 stop）
        return url
    }
    #endif

    /// 桥文件目录：优先用户授权的真实文件夹（macOS）；后备=沙盒容器（游戏读容器会被 TCC 拦，仅兜底）。
    private static func bridgeURL(_ name: String) -> URL? {
        #if os(macOS)
        if let folder = resolvedBridgeFolder() {
            return folder.appendingPathComponent(name)
        }
        #endif
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let bc = dir.appendingPathComponent("BetterCalendar", isDirectory: true)
        try? FileManager.default.createDirectory(at: bc, withIntermediateDirectories: true)
        return bc.appendingPathComponent(name)
    }

    /// 写入链路可见化（开发期铁律：失败不静默）：首次成功/路径变化打 info、失败打 error。
    private static var lastLoggedWritePath: String?

    private static var fileURL: URL? { bridgeURL("focus-state.json") }

    static func write(active: State.Active?, event: State.Event?) {
        guard !isTestHost, isEnabled, let url = fileURL else { return }
        let state = State(updatedAt: .now, active: active, lastEvent: event)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(state) else { return }
        do {
            try data.write(to: url, options: .atomic)
            if lastLoggedWritePath != url.path {
                lastLoggedWritePath = url.path
                DevLog.shared.info("聪音", "状态已写入 \(url.path)")
            }
        } catch {
            DevLog.shared.error("聪音", "状态写入失败（\(url.path)）：\(error.localizedDescription)")
        }
    }

    // MARK: 待办投影（SPEC §11 过审 2026-07-10）：今天的事项 → chiyne-todo.json → 游戏「Better Calendar」清单；
    // 游戏里勾完成 → mod 写 chiyne-inbox.json 回容器 → consumeInbox 消化成 BC 完成（同「提醒打勾」先例）。

    /// 待办投影开关（默认关）。mod 侧会写游戏存档（首次写入前 mod 自动备份）；关掉即删投影文件。
    static var todoProjectionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "integration.chiyneTodoProjection") }
        set {
            UserDefaults.standard.set(newValue, forKey: "integration.chiyneTodoProjection")
            if !newValue { try? bridgeURL("chiyne-todo.json").map { try FileManager.default.removeItem(at: $0) } }
        }
    }

    struct TodoItem: Codable {
        var id: String       // PlanBlock UUID 字符串（mod 藏进待办文本、回流按它认块）
        var title: String
        var done: Bool
    }
    private struct TodoProjection: Codable {
        var schemaVersion = 1
        var updatedAt: Date
        var items: [TodoItem]
    }

    static func writeTodoProjection(_ items: [TodoItem]) {
        guard !isTestHost, isEnabled, todoProjectionEnabled, let url = bridgeURL("chiyne-todo.json") else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(TodoProjection(updatedAt: .now, items: items)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 游戏里勾完成的回流：读并删 chiyne-inbox.json，返回完成的计划块 id。
    /// 不 gate 在开关上：开关关掉前游戏里勾的完成仍然是用户亲手勾的，照常消化。
    static func consumeInbox() -> [UUID] {
        guard !isTestHost, let url = bridgeURL("chiyne-inbox.json"),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return [] }
        try? FileManager.default.removeItem(at: url)
        struct Inbox: Codable { var completedIDs: [String] }
        let ids = (try? JSONDecoder().decode(Inbox.self, from: data))?.completedIDs ?? []
        return ids.compactMap(UUID.init(uuidString:))
    }

    /// 是否有待消化的回流（menu bar tick 的轻量探测，只查文件存在）。
    static var hasPendingInbox: Bool {
        guard let url = bridgeURL("chiyne-inbox.json") else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: 日历日档·日记槽（2026-07-10 过审）：复盘正反馈摘要 → chiyne-daily.json →
    // mod 追加进游戏日历当日日记（标记段替换=幂等、绝不覆盖用户手写；与待办投影同一把开关）。

    static func writeDailySummary(_ summary: String, logicalDay: Date) {
        guard !isTestHost, isEnabled, todoProjectionEnabled, !summary.isEmpty,
              let url = bridgeURL("chiyne-daily.json") else { return }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        struct Daily: Codable {
            var schemaVersion = 1
            var updatedAt: Date
            var date: String       // 逻辑日标签（凌晨复盘=写昨天那格）
            var summary: String
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(Daily(updatedAt: .now, date: df.string(from: logicalDay), summary: summary)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
