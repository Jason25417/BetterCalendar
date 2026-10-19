//
//  ReminderStore.swift
//  BetterCalendar
//
//  写标准 VTODO 提醒（标题/备注/截止/优先级）。priority 走 EKReminder 口径：0 无 / 1 高 / 5 中 / 9 低。
//  ⚠️ 旗标/标签/子任务是私有 ReminderKit，不可写——要紧事只能用 priority 表达。
//  生产实现 = ReminderProjector（决定逻辑）+ EventKitReminderStore（薄 EventKit 读写层，W12 拆开）；
//  测试注入 FakeReminderStore / 内存假列表（测试 target）。
//

import Foundation

struct ReminderDraft: Sendable, Identifiable {
    var id = UUID()
    var title: String
    var due: Date?
    var priority: Int = 0        // EKReminder 口径：0 无 / 1 高 / 5 中 / 9 低
    var notes: String?
    var leadMinutes: Int?        // 提前提醒：到期前 N 分钟响（nil = 不提醒）
    var blockID: UUID?           // 0.25.4：盖进提醒 URL（bettercalendar://block/UUID）——完成信号按 ID 精确匹配，不按标题
    var stamp: URL? = nil        // W12：显式章（「几点提醒我」= bettercalendar://reminder/ask/<id>）；nil = 按块 id / 标题算
}

/// 你自己列表里一条没完成的提醒（只读，给排程和智能体当上下文）。
nonisolated struct OwnReminder: Equatable, Sendable {
    var title: String
    var due: Date?
    /// 截止带不带具体时刻（只写了日期的提醒 = false）。
    var hasTime: Bool
    var list: String
}

/// 一次「跟上你在提醒事项里的操作」的结果。
nonisolated struct ReminderFollowReport: Sendable {
    var ops: [ReminderUserOp] = []
    /// 读取失败（没权限 / 系统读不到）：这次什么都没判断（绝不当成你删了）。
    var error: String? = nil
}

protocol ReminderStore: AnyObject {
    func write(_ drafts: [ReminderDraft]) async throws
    /// 按章差量写入（P4.0-9）：scope = 这次确认负责的块 id（其中不再需要提醒的才删）；别的日子的提醒不动。
    func sync(_ drafts: [ReminderDraft], scope: Set<UUID>, now: Date) async throws
    /// **今天**打勾完成、且带本 App 身份章的提醒的 blockID（被动信号按 ID 精确匹配——0.25.4 根治
    /// 「同名任务被往日打勾的旧提醒误标完成」）。无章老提醒不参与（宁可漏认，绝不误认）。
    func completedBlockIDs() async -> Set<UUID>
    /// 某日历日到期、未完成的提醒标题（排除本 App 自建列表），给排程当上下文。默认空。
    func dueReminders(on day: Date) async -> [String]
    /// 在 App 内完成一件事 → 把它对应的（带本 App 身份章的）提醒事项也勾成完成（双向：App→提醒事项）。
    /// 幂等：已完成的再勾一次无副作用。无章/无对应提醒的 blockID 忽略。默认 no-op（假实现/测试桩）。
    func markCompleted(blockIDs: Set<UUID>) async
    /// W12：跟上你在提醒事项里的操作（打勾 / 改时间 / 改文字 / 删除），记进投影账本。默认什么都不做。
    func followUserChanges(now: Date) async -> ReminderFollowReport
    /// W12：你自己列表里没完成的提醒（只读；不含 BetterCalendar 的列表）。读不到必须抛错，不能返回空冒充「没有」。
    func ownOpenReminders() async throws -> [OwnReminder]
}

extension ReminderStore {
    func sync(_ drafts: [ReminderDraft], scope: Set<UUID>, now: Date) async throws { try await write(drafts) }
    func dueReminders(on day: Date) async -> [String] { [] }
    func markCompleted(blockIDs: Set<UUID>) async {}
    func followUserChanges(now: Date) async -> ReminderFollowReport { ReminderFollowReport() }
    func ownOpenReminders() async throws -> [OwnReminder] { [] }
}

// MARK: - W12「几点提醒我」→ 提醒事项里的一条原生提醒

/// 写「几点提醒我」的结果。
nonisolated struct AskReminderReceipt: Equatable, Sendable {
    /// 撤销时核对的版本（标题 + 时刻；你在提醒事项里改过就对不上 → 不删）。
    var revision: String
    /// BetterCalendar 提醒列表所在的账户名（如「iCloud」）。
    var sourceName: String
}

nonisolated enum AskReminderError: Error, LocalizedError, Equatable {
    /// 没有提醒事项权限（这台设备）。
    case noAccess(String)
    /// BetterCalendar 的提醒列表只在这台设备上（本地账户），到不了另一台设备。
    case thisDeviceOnly(sourceName: String)
    /// 撤销时对不上（找不到 / 你改过 / 你勾掉了）。
    case conflict(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .noAccess(why): "没有提醒事项权限：\(why)"
        case let .thisDeviceOnly(source): "BetterCalendar 的提醒列表在「\(source)」里，只存在这台设备上，另一台设备收不到"
        case let .conflict(why): why
        case let .failed(why): why
        }
    }
    /// 可以改用「这台设备的本地通知」兜底的情况（其余失败直接报出来）。
    var allowsLocalFallback: Bool {
        switch self {
        case .noAccess, .thisDeviceOnly: true
        default: false
        }
    }
}

/// 执行器依赖的「几点提醒我」能力（生产 = ReminderProjector；测试 = 内存假列表上的 ReminderProjector）。
nonisolated protocol AskReminderProjecting: AnyObject, Sendable {
    /// 在 BetterCalendar 的提醒列表里写一条带提醒时刻的原生提醒（章 = bettercalendar://reminder/ask/<id>）。
    /// 列表只在本机（本地账户）→ 抛 thisDeviceOnly，**不写**（由执行器改用本机通知并写明）。幂等：同 id 已有就直接返回。
    func addAskReminder(id: UUID, title: String, body: String?, fireAt: Date) async throws -> AskReminderReceipt
    /// 撤销：删掉那条提醒。版本对不上（你改过 / 勾掉了）或找不到 → 抛 conflict，不删。返回给人看的一句话。
    func removeAskReminder(id: UUID, expectedRevision: String?) async throws -> String
    /// 幂等用：这条「几点提醒我」是否已经在提醒事项里（按章找，未勾掉的）。读不到 / 没权限 → nil（当作不知道，由调用方走正常路径）。
    /// 冒烟 2026-10-18 发现：执行成功但回报没落地 → App 重启后重复执行并误报「时刻已过」；先查这个就不会。
    func existingAskReminder(id: UUID) async -> AskReminderReceipt?
}

extension AskReminderProjecting {
    func existingAskReminder(id: UUID) async -> AskReminderReceipt? { nil }
}
