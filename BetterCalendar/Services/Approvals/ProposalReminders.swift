//
//  ProposalReminders.swift
//  BetterCalendar
//
//  SPEC §19.5 D3（W8，2026-10-18）：智能体经审批设「提醒」和「闹钟」。起因：真实对话里 Jason 说「明早 8 点叫我赶大巴」，
//  智能体只能回答做不到。
//  - 提醒 = 普通本地通知（UNUserNotificationCenter，复用 NativeReminderScheduler 的排程与核验）：**不保证叫醒**。
//  - 闹钟 = iPhone 系统闹钟（AlarmKit，复用 AlarmKitNativeAlarms）：会像闹钟一样响铃；只 iOS，Mac 上拒收、不降级成普通通知。
//  执行在目标设备上（审批卡写清设备与时刻）；撤销 = 取消排程 / 取消闹钟（只能在设好的那台设备上撤销）。
//

import Foundation

/// 提醒 / 闹钟的规则（纯数据）。
nonisolated enum ProposalReminderRules {
    /// 至少提前多久（太近的时刻来不及审批 + 排程）。有效性边界（Jason 认可：为了干净防 bug）。
    static let minLead: TimeInterval = 60
    // W10：「最远 30 天以内」已取消（判断类数字，由智能体按上下文判断）。
    static let titleLimit = 150
    static let bodyLimit = 500

    /// 给人看的时刻：「10月19日 08:00」。
    static func when(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }
}

/// 执行器依赖的排程能力（生产 = NativeProposalNotificationScheduler；测试 = 内存假实现）。
@MainActor protocol ProposalNotificationScheduling: AnyObject {
    /// 这台设备能不能设系统闹钟（只有 iPhone 能）。
    var alarmsSupported: Bool { get }
    /// 排一条普通提醒；返回设好后的版本（撤销时核对）。
    func scheduleReminder(id: UUID, title: String, body: String, fireAt: Date) async throws -> String
    /// 取消提醒；版本已变（之后被改过）→ conflict。已取消视为成功。
    func cancelReminder(id: UUID, expectedRevision: String?) async throws
    func scheduleAlarm(id: UUID, title: String, fireAt: Date) async throws
    func cancelAlarm(id: UUID) async throws
}

/// 生产实现：普通提醒走 NativeReminderScheduler（排程后回读核验），闹钟走 NativeAlarmScheduling（iOS = AlarmKit）。
@MainActor final class NativeProposalNotificationScheduler: ProposalNotificationScheduling {
    private let reminders: NativeReminderScheduler
    private let alarms: any NativeAlarmScheduling

    init(reminders: NativeReminderScheduler, alarms: any NativeAlarmScheduling) {
        self.reminders = reminders; self.alarms = alarms
    }

    var alarmsSupported: Bool { alarms.inspect().supported }

    func scheduleReminder(id: UUID, title: String, body: String, fireAt: Date) async throws -> String {
        let change = NativeReminderChange(commandId: id, reminderId: id, action: .schedule, expectedRevision: nil,
                                          title: title, body: body, fireAt: fireAt, sound: true, experiment: false)
        do { _ = try await reminders.apply(change, userConfirmed: true, grantCurrent: { true }) } catch {
            throw ProposalExecutionError.unavailable("提醒没排上：\(error.localizedDescription)（需要允许 BetterCalendar 发通知）")
        }
        guard let record = try reminders.records().first(where: { $0.id == id }) else {
            throw ProposalExecutionError.unavailable("提醒已提交系统，但本机记录里找不到，结果未知")
        }
        return record.revision
    }

    func cancelReminder(id: UUID, expectedRevision: String?) async throws {
        guard let record = try reminders.records().first(where: { $0.id == id }) else {
            throw ProposalExecutionError.conflict("这台设备上找不到这条提醒（可能不是在这台设备上设的）")
        }
        if record.cancelled { return }
        if let expectedRevision, record.revision != expectedRevision {
            throw ProposalExecutionError.conflict("这条提醒在设好之后被改过")
        }
        _ = try await reminders.apply(NativeReminderChange(commandId: UUID(), reminderId: id, action: .cancel, expectedRevision: record.revision),
                                      userConfirmed: true, grantCurrent: { true })
    }

    func scheduleAlarm(id: UUID, title: String, fireAt: Date) async throws {
        var capability = alarms.inspect()
        guard capability.supported else {
            throw ProposalExecutionError.unavailable("这台设备不能设系统闹钟（只有 iPhone 可以）；没有改用普通通知")
        }
        if capability.authorization == "not_determined" { capability = try await alarms.requestAuthorization() }
        guard capability.authorization == "authorized" else {
            throw ProposalExecutionError.unavailable("还没允许 BetterCalendar 设闹钟：到 iPhone 的 设置 → BetterCalendar 打开「闹钟」后再试")
        }
        _ = try await alarms.schedule(NativeAlarmRequest(commandId: id, fireAt: fireAt, title: title,
                                                         userAuthorizationRef: "bc-proposal:" + id.uuidString), userConfirmed: true)
    }

    func cancelAlarm(id: UUID) async throws {
        _ = try alarms.cancel(commandId: UUID(), alarmId: id, userConfirmed: true)
    }
}
