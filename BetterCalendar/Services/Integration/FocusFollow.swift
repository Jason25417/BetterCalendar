//
//  FocusFollow.swift
//  BetterCalendar
//
//  多端跟随专注（#30，2026-07-11 哲学审核过审，V1「跟随开始」）：
//  一端 start/complete → CloudKit 单记录 runstate + 静默推送 → 另一端进入/退出「跟随陪伴」显示态
//  （menu bar / 今天页显示同任务计时；iPhone 可联动番茄屏蔽）。
//  审核红线：默认关；**跟随端绝不落任何本地记录**（session/行为/实际/日历全无——记录归发起端，
//  iCloud 自然同步）；一键退出；失同步静默自愈（推送错过靠前台 catch-up 兜底，同聪音对账哲学）。
//  诚实预期：准实时（秒~十几秒，受系统推送调度影响）。
//  ⚠️ 新记录类型 FocusRunState：TestFlight（生产环境）生效前需 CloudKit Console 手动
//  Deploy Schema to Production（同 M7 流程）——开发环境（Xcode 直装）自动建 schema。
//

import Foundation
import CloudKit

enum FocusFollowSettings {
    /// 总开关（默认关；红线①）。
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "integration.focusFollow") }
        set { UserDefaults.standard.set(newValue, forKey: "integration.focusFollow") }
    }
}

/// 跟随态（另一台设备正在做的事）：只读展示 + （iOS）联动屏蔽，绝不产生本地记录。
@Observable
final class FollowRunState {
    static let shared = FollowRunState()

    struct Run {
        var title: String
        var style: String        // light / pomodoro / none
        var startedAt: Date      // 已按 elapsed 折算，直接 now-startedAt 即「已多久」
        var seq: Int64           // 来源记录 seq（退出跟随后按它静音，防 catch-up 复活）
    }

    private(set) var run: Run?
    private var mutedSeq: Int64 = -1
    /// 跟随态变化钩子（组装点接 VM 的屏蔽收敛，跟随也走「工作段=屏蔽」同一纯函数）。
    var onChange: (() -> Void)?

    /// 跟随中且是番茄 → 参与屏蔽谓词（VM updateScreenTimeShield 里 OR 进去）。
    var shouldShield: Bool { run?.style == "pomodoro" }

    func set(_ r: Run?) {
        if let r, r.seq == mutedSeq { return }   // 用户退出过这一轮跟随 → 静音
        let changed = (run?.title != r?.title) || (run == nil) != (r == nil)
        run = r
        if changed { onChange?() }
    }

    /// 一键退出（红线③）：本轮 seq 静音，直到对面下一个新事件才可能再跟随。
    func exitFollow() {
        mutedSeq = run?.seq ?? -1
        run = nil
        onChange?()
        DevLog.shared.info("跟随", "已退出本轮跟随（对面下个新动作前不再跟）")
    }
}

/// CloudKit 通道：单记录 runstate（覆盖写）+ CKQuerySubscription 静默推送 + 前台 catch-up 兜底。
enum FocusFollow {
    static let recordType = "FocusRunState"
    private static let recordID = CKRecord.ID(recordName: "focus-run-state")
    private static let subscriptionID = "focus-follow-sub"
    private static var db: CKDatabase {
        CKContainer(identifier: "iCloud.com.jason.BetterCalendar").privateCloudDatabase
    }

    /// 本机身份（区分发起端/跟随端）。
    static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "integration.focusFollowDeviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "integration.focusFollowDeviceID")
        return id
    }

    private static var lastTickPublish: Date = .distantPast

    /// 发布本机 runstate（exportFocusState 钩子）：start/complete 即时；tick 5 分钟节流（保新鲜度，
    /// 供 catch-up 判断「对面还活着吗」）。开关关=不出网。
    static func publish(kind: String, active: FocusStateExporter.State.Active?) {
        guard FocusFollowSettings.enabled else { return }
        if kind == "tick" {
            guard active != nil, Date.now.timeIntervalSince(lastTickPublish) >= 300 else { return }
            lastTickPublish = .now
        }
        let a = active
        Task {
            do {
                let record: CKRecord
                do { record = try await db.record(for: recordID) }
                catch { record = CKRecord(recordType: recordType, recordID: recordID) }
                record["deviceID"] = deviceID
                record["action"] = kind
                record["hasActive"] = (a != nil) ? 1 : 0
                record["title"] = a?.title ?? ""
                record["style"] = a?.timingStyle ?? ""
                // startedAt 直接给「折算后」起点：now - elapsed（跟随端 now-startedAt 即已多久）
                record["startedAt"] = a.map { Date.now.addingTimeInterval(-TimeInterval($0.elapsedSec)) } ?? Date.distantPast
                record["seq"] = Int64(Date.now.timeIntervalSince1970 * 1000)
                record["updatedAt"] = Date.now
                _ = try await db.save(record)
            } catch {
                // 失同步静默（红线：不弹焦虑）；开发期照可见报错约定进日志
                DevLog.shared.warn("跟随", "runstate 发布失败：\(error.localizedDescription)")
            }
        }
    }

    /// 订阅另一端的 runstate 变化（静默推送）。幂等：重复保存同 ID 订阅无害。
    static func ensureSubscription() async {
        guard FocusFollowSettings.enabled else { return }
        let sub = CKQuerySubscription(recordType: recordType, predicate: NSPredicate(value: true),
                                      subscriptionID: subscriptionID,
                                      options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // 静默推送：不打扰（通知铁则不受影响）
        sub.notificationInfo = info
        do {
            _ = try await db.save(sub)
            DevLog.shared.info("跟随", "CloudKit 订阅就绪（focus-follow-sub）")
        } catch {
            DevLog.shared.warn("跟随", "订阅创建失败：\(error.localizedDescription)")
        }
    }

    /// 远程静默推送入口（双端 AppDelegate 转发进来）。
    static func handlePush(_ userInfo: [AnyHashable: Any]) {
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo),
              note.subscriptionID == subscriptionID else { return }
        Task { await refreshAndApply(reason: "推送") }
    }

    /// 拉取最新 runstate 并收敛本机跟随态（推送触发 + 前台 catch-up 兜底，level-triggered）。
    static func refreshAndApply(reason: String) async {
        guard FocusFollowSettings.enabled else { return }
        do {
            let record = try await db.record(for: recordID)
            apply(record, reason: reason)
        } catch let e as CKError where e.code == .unknownItem {
            // 对面从没发布过：无事
        } catch {
            DevLog.shared.warn("跟随", "runstate 拉取失败（\(reason)）：\(error.localizedDescription)")
        }
    }

    private static func apply(_ record: CKRecord, reason: String) {
        guard (record["deviceID"] as? String) != deviceID else { return }   // 自己发的不跟
        let updatedAt = (record["updatedAt"] as? Date) ?? .distantPast
        let hasActive = ((record["hasActive"] as? Int) ?? 0) == 1
        let seq = (record["seq"] as? Int64) ?? 0
        // 新鲜度：发布端活着时 tick 5 分钟一续——超过 12 分钟没动=对面多半退了，不再跟随（失同步静默）
        guard hasActive, Date.now.timeIntervalSince(updatedAt) < 720 else {
            FollowRunState.shared.set(nil)
            return
        }
        let title = (record["title"] as? String) ?? ""
        let style = (record["style"] as? String) ?? "light"
        let startedAt = (record["startedAt"] as? Date) ?? .now
        guard !title.isEmpty else { FollowRunState.shared.set(nil); return }
        FollowRunState.shared.set(.init(title: title, style: style, startedAt: startedAt, seq: seq))
        DevLog.shared.info("跟随", "跟上另一台设备（\(reason)）：「\(title)」\(style) · 已 \(Int(Date.now.timeIntervalSince(startedAt)))s")
    }
}
