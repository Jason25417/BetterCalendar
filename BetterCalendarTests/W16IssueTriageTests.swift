import Foundation
import Testing
@testable import BetterCalendar

/// W16（SPEC §19.9 欠账① 中间步「安静但可见」）：失败分级 + 横幅 / 🐞 计数 / 升级 / 恢复。
/// 每个用例用独立的 DevLog 实例 + 注入时钟，不碰 DevLog.shared。
@MainActor @Suite struct W16IssueTriageTests {
    static let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    final class Clock { var now = W16IssueTriageTests.t0 }

    func makeLog() -> (DevLog, Clock) {
        let log = DevLog(), clock = Clock()
        log.now = { clock.now }
        return (log, clock)
    }

    @Test func classifiesActionableTransientInfo() {
        func tier(_ l: DevLog.Level, _ s: String, _ m: String) -> IssueTriage.Tier { IssueTriage.classify(level: l, source: s, message: m).tier }
        // (a) 缺 key / 没登录 iCloud / 缺通知权限
        #expect(tier(.warning, "排程", "云端失败，回退本地：未配置 API key") == .actionable)
        #expect(tier(.error, "多端审批", "读取提案失败：The operation couldn’t be completed. (CKErrorDomain error 9.)") == .actionable)
        #expect(tier(.warning, "通知", "请求授权失败：denied") == .actionable)
        // (b) 热点上 CKError 3、端侧解析被取消、云端降级
        #expect(tier(.error, "多端审批", "读取提案失败：The operation couldn’t be completed. (CKErrorDomain error 3.)") == .transient)
        #expect(tier(.warning, "端侧解析", "Foundation Models 失手：The operation couldn’t be completed. (Swift.CancellationError error 1.)") == .transient)
        #expect(tier(.warning, "排程", "云端失败，回退本地：Anthropic HTTP 529：overloaded") == .transient)
        // 说明性 / 冻结子系统：只进日志
        #expect(tier(.warning, "通知", "早提醒没排：07:30 已过当前时刻") == .info)
        #expect(tier(.warning, "StateBridge", "浏览器状态读取未成功") == .info)
        // 未登记：error 横幅、warning 安静
        #expect(tier(.error, "执行", "写入实际日历失败：x") == .actionable)
        #expect(tier(.warning, "某新来源", "随便什么") == .transient)
    }

    @Test func transientIsQuietThenAutoDecays() {
        let (log, clock) = makeLog()
        log.warn("端侧解析", "Foundation Models 失手：CancellationError")
        #expect(log.bannerIssue == nil)
        #expect(log.quietIssueCount == 1)
        #expect(log.entries.count == 1)   // 日志一条不少
        clock.now = Self.t0.addingTimeInterval(IssueTriage.quietDecay + 1)
        #expect(log.quietIssueCount == 0)   // 不再出现 = 视为恢复
        #expect(log.entries.count == 1)
    }

    @Test func repeatedTransientEscalatesToBanner() {
        let (log, clock) = makeLog()
        log.warn("排程", "云端失败，回退本地：Anthropic HTTP 503")
        clock.now = Self.t0.addingTimeInterval(8 * 60)
        log.warn("排程", "云端失败，回退本地：Anthropic HTTP 503")
        #expect(log.bannerIssue == nil)
        clock.now = Self.t0.addingTimeInterval(IssueTriage.escalateAfter + 60)
        log.warn("排程", "云端失败，回退本地：Anthropic HTTP 503")
        let b = try! #require(log.bannerIssue)
        #expect(b.escalated)
        #expect(!b.text.contains("HTTP 503"))   // 原始错误码只在日志里
        #expect(log.quietIssueCount == 0)
    }

    @Test func recoverySignalClearsAndUnrecoveredEscalates() {
        let (log, clock) = makeLog()
        log.error("多端审批", "读取提案失败：(CKErrorDomain error 3.)")
        #expect(log.bannerIssue == nil)
        #expect(log.quietIssueCount == 1)
        #expect(!log.shouldShowInline(source: "多端审批", message: "读取提案失败：(CKErrorDomain error 3.)"))
        log.resolve(source: "多端审批")
        #expect(log.quietIssueCount == 0)
        #expect(log.entries.last?.message.contains("已恢复") == true)
        // 有恢复信号的通道：失败后 escalateAfter 内没恢复 → 升级（不必重复出现）
        log.error("多端审批", "读取提案失败：(CKErrorDomain error 3.)")
        clock.now = Self.t0.addingTimeInterval(IssueTriage.escalateAfter + 1)
        #expect(log.bannerIssue?.escalated == true)
        #expect(log.shouldShowInline(source: "多端审批", message: "读取提案失败：(CKErrorDomain error 3.)"))
    }

    @Test func actionableBannerHasPlainActionAndAcknowledge() {
        let (log, clock) = makeLog()
        log.warn("排程", "云端失败，回退本地：未配置 API key")
        let b = try! #require(log.bannerIssue)
        #expect(!b.escalated)
        #expect(b.action?.contains("设置") == true)
        log.acknowledge(b.key)
        #expect(log.bannerIssue == nil)
        clock.now = Self.t0.addingTimeInterval(60)
        log.warn("排程", "云端失败，回退本地：未配置 API key")
        #expect(log.bannerIssue != nil)   // 再出现才重新横幅
    }

    @Test func plainTextStripsRawErrorTailOnly() {
        #expect(IssueTriage.plainText("写入实际日历失败：The operation couldn’t be completed. (EKErrorDomain error 1.)") == "写入实际日历失败")
        #expect(IssueTriage.plainText("提案已停止等待：到对话页重试") == "提案已停止等待：到对话页重试")
    }

    @Test func developerSwitchIsSynced() {
        #expect(SettingsSync.syncedKeys.contains(DeveloperSettings.key))
        #expect(SettingsSync.deviceLocalKeys[DeveloperSettings.key] == nil)
    }
}
