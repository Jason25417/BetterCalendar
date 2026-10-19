//
//  IssueTriage.swift
//  BetterCalendar
//
//  失败分级（SPEC §19.9 欠账① 的中间步「安静但可见」，W16 2026-10-19）：
//  开发期所有失败照旧**完整**进 DevLog（一条不吞），但「要不要打扰你」统一在这里判，各处不再各自决定——
//    (a) 你现在能处理的（缺权限、缺 key、没登录 iCloud、文件夹授权失效）→ 横幅，白话说清「发生了什么 + 怎么办」；
//    (b) 短暂、会自己恢复的（热点上 iCloud 报 CKError 3、云端赢了时端侧解析被取消、同步重试后成功）→ 不弹横幅，
//        只在 🐞 入口点一个小计数；恢复（成功信号或一段时间不再出现）后自动消失；
//    (c) 持续失败（同一件事反复失败超过 escalateAfter 分钟 / 有恢复信号的通道一直没恢复）→ 升级成横幅。
//  原始错误码只进日志；横幅只说人话。规则表是唯一真相源：新增失败点不用改这里也有合理默认
//  （未登记的 error → 横幅；未登记的 warning → 安静 + 可升级）。上架前切静默自愈时，也只改这一处。
//

import Foundation

nonisolated enum IssueTriage {
    /// (a)/(b)/(c) 中 a、b 两档 + 只记不提醒的说明性条目；(c) 是 (b) 的运行时状态（见 DevLog.IssueState）。
    enum Tier: String, Sendable {
        case actionable   // (a) 横幅：你现在能处理
        case transient    // (b) 安静：🐞 计数，恢复即消失；持续则升级（c）
        case info         // 说明性警告（如「早提醒没排：已过当前时刻」）：只进日志，不计数、不升级
    }

    struct Verdict: Equatable, Sendable {
        let tier: Tier
        /// 同一类问题的归并键（升级/恢复/「知道了」都按它）。
        let key: String
        /// 横幅白话标题（nil = 用原文去掉错误码的部分）。
        let headline: String?
        /// 横幅上的「怎么办」（nil = 只给「点开看详情」）。
        let action: String?
        let ruleID: String
    }

    /// 持续多久算 (c)：同一类问题反复出现跨度 ≥ 这个值，或有恢复信号的通道失败后这么久还没恢复。
    static let escalateAfter: TimeInterval = 15 * 60
    /// 没有恢复信号的 (b)：这么久不再出现 = 视为已恢复，计数自动消失（日志原样保留）。
    static let quietDecay: TimeInterval = 30 * 60
    /// 这些来源有明确的「成功」信号（调用 DevLog.resolve(source:)）：失败后 escalateAfter 内没等到恢复就升级。
    static let sourcesWithRecoverySignal: Set<String> = ["数据同步", "多端审批", "智能体对话", "智能体消息"]

    // MARK: 规则表（先匹配先得；匹配前统一小写）

    private struct Rule {
        let id: String
        let sources: Set<String>?          // nil = 任何来源
        let patterns: [String]             // 任一子串命中（小写比较）；空 = 只按来源
        let tier: Tier
        let headline: String?
        let action: String?
    }

    /// 已冻结的 Dots 时代子系统：默认不运行；开着时的任何失败都只进日志（不打扰）。
    static let frozenSources: Set<String> = ["StateBridge", "BC 审批", "BC计时", "对话操作", "对话操作日志", "原生操作", "本机操作记录"]

    private static let rules: [Rule] = [
        // —— (a) 你现在能处理 ——
        Rule(id: "key.sentinel", sources: nil, patterns: ["没有 openrouter api key", "没有 openai api key"], tier: .actionable,
             headline: "哨兵的判断模型没有 key，暂时用兜底判断",
             action: "到 多端审批 → 哨兵 里填好 key"),
        Rule(id: "key.cloud", sources: nil,
             patterns: ["未配置 api key", "未配 api key", "没有 anthropic api key", "x-api-key", "authentication_error", "http 401", "invalid api key"],
             tier: .actionable,
             headline: "云端 AI 的 key 没填或已失效，现在只能用本地/端侧排",
             action: "到 设置 → 云端排程大脑 填好 key，点「测试」确认"),
        Rule(id: "icloud.account", sources: nil,
             patterns: ["ckerrordomain error 9.", "not authenticated", "notauthenticated", "no icloud account", "icloud 不可用", "未登录 icloud"],
             tier: .actionable,
             headline: "这台设备没登录 iCloud（或 iCloud 暂不可用），多端同步停了",
             action: "到 系统设置 → Apple 账户 登录 iCloud 并打开 iCloud 云盘"),
        Rule(id: "icloud.quota", sources: nil, patterns: ["ckerrordomain error 25.", "quota exceeded", "quotaexceeded"], tier: .actionable,
             headline: "iCloud 存储空间满了，新的改动传不上去",
             action: "清理 iCloud 空间或升级存储方案"),
        Rule(id: "perm.notify", sources: ["通知"], patterns: ["授权"], tier: .actionable,
             headline: "BetterCalendar 没有发通知的权限",
             action: "到 系统设置 → 通知 → BetterCalendar 打开「允许通知」"),
        Rule(id: "perm.shield", sources: ["屏蔽"], patterns: [], tier: .actionable,
             headline: "「屏幕使用时间」授权没拿到，番茄绝对专注用不了",
             action: "到 系统设置 → 屏幕使用时间 允许 BetterCalendar 后再打开"),
        Rule(id: "perm.calendar", sources: nil,
             patterns: ["没有日历权限", "日历权限", "提醒事项权限", "access denied", "not authorized", "未授权"], tier: .actionable,
             headline: "缺少日历 / 提醒事项权限，相关内容没写进去",
             action: "到 系统设置 → 隐私与安全性 → 日历 / 提醒事项 允许 BetterCalendar（完全访问）"),
        Rule(id: "folder.bookmark", sources: nil, patterns: ["书签", "目录授权已失效", "重新选择"], tier: .actionable,
             headline: "文件夹授权失效了",
             action: "重新选一次文件夹（智能体：多端审批 → 智能体桥接；聪音：设置 → 进阶设置）"),
        Rule(id: "login.item", sources: ["设置"], patterns: ["开机自启"], tier: .actionable,
             headline: "开机自动启动没设上",
             action: "到 系统设置 → 通用 → 登录项 里手动添加 BetterCalendar"),
        // 真实数据可能没落地：即使是 warning 也要横幅
        Rule(id: "data.session", sources: ["计时历史"], patterns: [], tier: .actionable,
             headline: "一段计时记录没存上", action: "点开日志看是哪一段；需要的话在今天页补一笔"),
        Rule(id: "data.todo", sources: ["对账"], patterns: ["没能收进待办区"], tier: .actionable,
             headline: "有一块从时间线移走了，但没能收进待办区", action: "到 设置 → 数据与同步 → 回收站 找回"),

        // —— (b) 短暂、会自己恢复 ——（按错误内容，任何来源）
        Rule(id: "net.transient", sources: nil, patterns: [
            "ckerrordomain error 3.", "ckerrordomain error 4.", "ckerrordomain error 6.", "ckerrordomain error 7.",
            "ckerrordomain error 20.", "ckerrordomain error 22.", "ckerrordomain error 23.",
            "network unavailable", "network failure", "networkunavailable", "networkfailure",
            "service unavailable", "request rate limited", "zone busy", "nsurlerrordomain",
            "internet connection appears to be offline", "network connection was lost", "timed out",
            "互联网连接", "网络连接", "网络不通", "请求超时", "已超时",
            "http 429", "http 500", "http 502", "http 503", "http 504", "http 529", "overloaded",
        ], tier: .transient, headline: "网络或 iCloud 暂时不通，恢复后会自动补上", action: "通常不用管；一直不好就换个网络或点开日志"),
        Rule(id: "cancelled", sources: nil, patterns: ["cancellationerror", "cancelled", "已取消", "operation was canceled"], tier: .transient,
             headline: nil, action: nil),

        // —— 有兜底的降级（结果照样出来了）：安静，反复出现才升级 ——
        Rule(id: "fallback.ai", sources: ["端侧解析", "端侧微调", "微调", "排程", "reflow", "解析", "脱敏排序", "分步排序", "云端", "云端原文", "长期"],
             patterns: [], tier: .transient,
             headline: "AI 排程这阵子一直没成功，用的是本地兜底", action: "检查网络和 设置 → 云端排程大脑 的 key；点开日志看原因"),
        Rule(id: "cloud.off", sources: nil, patterns: ["云端已关闭"], tier: .info, headline: nil, action: nil),
        Rule(id: "redraw.later", sources: ["投影", "对账", "时间线", "绿色淡出", "智能体运行", "智能体上下文", "设备活动", "共享计时", "多端审批", "数据同步"],
             patterns: ["下次", "再试", "兜底", "补报", "待传", "轮询", "暂不", "这一轮", "没传上"], tier: .transient,
             headline: nil, action: nil),
        Rule(id: "sentinel.fallback", sources: ["哨兵"], patterns: ["没用上首选", "这一轮只看"], tier: .transient,
             headline: "哨兵这阵子一直用兜底判断", action: "到 多端审批 → 哨兵 看原因"),

        // —— 说明性：只进日志 ——
        Rule(id: "info.notify-past", sources: ["通知"], patterns: ["已过当前时刻"], tier: .info, headline: nil, action: nil),
        Rule(id: "info.spill", sources: ["溢出"], patterns: [], tier: .info, headline: nil, action: nil),
        Rule(id: "info.trash-kept", sources: ["PlanStore"], patterns: ["保持在回收站"], tier: .info, headline: nil, action: nil),
        Rule(id: "info.todo-misuse", sources: ["待办区"], patterns: [], tier: .info, headline: nil, action: nil),
        Rule(id: "info.reminder-unmatched", sources: ["提醒"], patterns: ["没有改动"], tier: .info, headline: nil, action: nil),
        Rule(id: "info.reminder-local", sources: ["提醒"], patterns: ["改用这台设备的本机通知"], tier: .info, headline: nil, action: nil),
        Rule(id: "info.mark-unmatched", sources: ["执行"], patterns: ["没找到匹配"], tier: .info, headline: nil, action: nil),
        Rule(id: "info.forbidden-words", sources: ["智能体对话"], patterns: ["正反馈原则禁用的词"], tier: .info, headline: nil, action: nil),
    ]

    /// 纯函数：一条日志 → 分级。info 级日志一律 .info。
    static func classify(level: DevLog.Level, source: String, message: String) -> Verdict {
        guard level != .info else { return Verdict(tier: .info, key: "info·\(source)", headline: nil, action: nil, ruleID: "level.info") }
        if frozenSources.contains(source) {
            return Verdict(tier: .info, key: "frozen·\(source)", headline: nil, action: nil, ruleID: "frozen.dots")
        }
        let lower = message.lowercased()
        for r in rules {
            if let s = r.sources, !s.contains(source) { continue }
            if !r.patterns.isEmpty, !r.patterns.contains(where: { lower.contains($0) }) { continue }
            return Verdict(tier: r.tier, key: "\(source)·\(r.id)", headline: r.headline, action: r.action, ruleID: r.id)
        }
        // 未登记：error 照旧横幅（宁可多见），warning 安静 + 持续才升级
        return level == .error
            ? Verdict(tier: .actionable, key: "\(source)·error", headline: nil, action: nil, ruleID: "default.error")
            : Verdict(tier: .transient, key: "\(source)·warning", headline: nil, action: nil, ruleID: "default.warning")
    }

    /// 横幅白话：去掉「：<系统错误原文>」尾巴（原文只进日志）。
    static func plainText(_ message: String) -> String {
        guard let r = message.range(of: "：") else { return message }
        let head = String(message[..<r.lowerBound])
        let tail = message[r.upperBound...].lowercased()
        // 只在尾巴像系统错误原文时才截（英文/错误码），中文说明句保留全文
        let looksRaw = tail.contains("error") || tail.contains("the operation") || tail.contains("couldn’t")
            || tail.contains("couldn't") || tail.contains("http ") || tail.range(of: "[a-z]{6,}", options: .regularExpression) != nil
        return looksRaw && head.count >= 3 ? head : message
    }
}
