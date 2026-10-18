//
//  ReminderOpsRecorder.swift
//  BetterCalendar
//
//  W12（SPEC §19.13 Q5，原则 8）：你在提醒事项里的操作 = 你的操作。BetterCalendar 跟上并记下、绝不改回：
//    - 每一条写进操作留底（来源 = 你，在提醒事项里），一句白话；
//    - 待办池截止的提醒被你今天勾掉 → 对应待办算做成了（计划块的打勾走 completedBlockIDs → 画蓝，路径不变）。
//  改时间 / 删除只记账（账本在 ReminderProjector 里已经更新：下次同步不改回、不重建），这件事本身不动。
//

import Foundation

/// 「待办池截止提醒被勾掉 → 这件待办做成了」（唯一写者 = LongTaskStore）。
@MainActor protocol PoolDeadlineCompleting: AnyObject {
    /// 按章找到在途、带截止的那件待办并标完成；返回它的标题（找不到 = nil）。
    func completePoolItem(stampKey: String) -> String?
}

extension LongTaskStore: PoolDeadlineCompleting {
    func completePoolItem(stampKey: String) -> String? {
        guard let task = (todoItems() + active()).first(where: {
            $0.deadline != nil && ReminderStamp.key(ReminderStamp.poolURL(title: $0.title)) == stampKey
        }) else { return nil }
        complete(task)
        return task.title
    }
}

@MainActor final class ReminderOpsRecorder {
    private let ledger: any OperationLedger
    private let deviceId: String
    private weak var pool: (any PoolDeadlineCompleting)?
    private let now: () -> Date

    init(ledger: any OperationLedger, deviceId: String, pool: (any PoolDeadlineCompleting)?, now: @escaping () -> Date = { .now }) {
        self.ledger = ledger; self.deviceId = deviceId; self.pool = pool; self.now = now
    }

    func record(_ ops: [ReminderUserOp]) {
        let at = now()
        for op in ops {
            var detail = op.line
            // 待办池截止：今天勾掉的才算（不翻旧账，同计划块的「只认今天打勾」）
            if op.kind == .completed, op.projection == .pool,
               DayContext.isSameLogicalDay(op.completedAt ?? at, at) {
                if let title = pool?.completePoolItem(stampKey: op.stamp) {
                    detail += "：「\(title)」算做成了"
                    DevLog.shared.info("提醒", "提醒事项里勾掉了「\(title)」→ 待办标为做成了")
                } else {
                    DevLog.shared.warn("提醒", "提醒事项里勾掉了「\(op.title)」，但 BetterCalendar 里没找到在途的这件待办（可能已完成或改了名），没有改动")
                }
            }
            ledger.append(OperationRecord(at: at, actor: .user, actorLabel: "你（在提醒事项里）", deviceId: deviceId,
                                          event: "reminder." + op.kind.rawValue, proposalId: nil, parentId: nil,
                                          parentRef: op.stamp, detail: detail))
        }
    }
}
