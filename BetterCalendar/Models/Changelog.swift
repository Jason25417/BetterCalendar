//
//  Changelog.swift
//  BetterCalendar
//
//  应用基本信息 + 应用内更新日志（左下角可点版本号 → 弹更新日志）。
//  版本号读自工程的 MARKETING_VERSION（CFBundleShortVersionString）。
//  规则：第三节（补丁）每次改动自增；大/中版本要改先与作者确认。
//

import Foundation

enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
    static let author = "Jason Tu"
    static let name = "BetterCalendar"
    static var copyright: String { "© 2026 \(author) · \(name)" }
}

struct ChangelogEntry: Identifiable {
    let id = UUID()
    let version: String
    let date: String
    let changes: [String]
}

/// 更新日志：以后每改一版，在最前面加 / 更新一条。
enum Changelog {
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(version: "0.6.3", date: "2026-07", changes: [
            "硬截止（DDL）贯通：说「10 点前必须交」AI 解析的 DDL 现在会显示在草稿行（🏁红旗）、写进提醒事项并按它提前提醒",
            "带 DDL 的事即使不标 ★要紧 也会进提醒事项（要紧=高优先级、DDL=中优先级）",
        ]),
        ChangelogEntry(version: "0.6.2", date: "2026-07", changes: [
            "修复：确认写入跨日草稿（排到次日凌晨）时真相源残留旧块",
            "修复：Live Activity 数据类型的 Swift 6 并发告警（隔离一致性）",
        ]),
        ChangelogEntry(version: "0.6.1", date: "2026-07", changes: [
            "实际(蓝色)写入改为「合并不覆盖」：menu bar 采集、复盘回填、另一台设备三方并发都不会互删",
        ]),
        ChangelogEntry(version: "0.6", date: "2026-07", changes: [
            "首个 TestFlight 内测版：图标、隐私清单、双端发版适配全就绪（更新走 TestFlight 自动提示）",
            "活跃天数 / 今日 MVP 改为 iCloud 跨端同步（原来 Mac/iPhone 各记各的；旧数据自动迁移）",
            "API key 随 iCloud 钥匙串同步：Mac 存一次，iPhone 直接可用",
            "修复：macOS「导出 ICS」存盘失败（沙盒权限）；iOS 小组件库不再出现模板占位组件",
        ]),
        ChangelogEntry(version: "0.5", date: "2026-07", changes: [
            "Siri / 快捷指令 / Spotlight：说「排今天 / 开始今天 / 开始专注 / 完成当前 / 打开复盘」直接触发，无需先打开 App",
            "Handoff 跨设备接力：在一台设备上做到哪，另一台顶部/程序坞点一下就续上当前页面",
            "复盘页「分享今日小结」：一键分享今天做成了什么（正反馈措辞，默认不含缺口）",
            "iOS 修复：补上启动屏，去掉启动黑屏 / 画面不占满屏（letterbox）",
        ]),
        ChangelogEntry(version: "0.4", date: "2026-07", changes: [
            "iOS 适配：三 tab（排日程/今天/日记）+ App 内设置页 + ICS 用 ShareLink 分享",
            "Live Activity（iOS）：执行时灵动岛 + 锁屏实时计时——轻计时正计/番茄段倒计/休息冻结，系统自动跑不耗电",
            "并行多任务：前台一件精细计时，「同时做」把别的事放后台并行（自己按墙钟跑、✓ 完成自动记蓝色实际）",
            "排日程页自动加载所选目标日的已确认计划（标「已确认的计划」，改动后再点确认写入生效）",
            "macOS：点红叉关窗不退出、menu bar 计时常驻；修菜单栏弹窗在其他 App/全屏页看不见",
        ]),
        ChangelogEntry(version: "0.3", date: "2026-06", changes: [
            "M5 自愈 re-flow：三色日历（绿计划/蓝实际/橙预览）+「开始今天」晨间重排 + 全天连续橙色预览（被实际蚕食、日终消失）；撞固定块由 LLM 智能重排避让",
            "计划块真相源迁到 SwiftData（PlanStore），reflow 能读回固定/优先级；逻辑日 DayContext（凌晨 4 点日界线 + 智能默认排今天/明天）",
            "M4 签名功能：计划(绿) × 实际(蓝) 对比 + 正反馈复盘——只放大「做成了什么」（含计划外 bonus），完成率/缺口默认隐藏",
            "menu bar 单键导航（记录=导航）：当前块·已用时长·下一件，完成/换一件/休息(单键toggle)，顺手攒蓝色实际日历",
            "晚间回填降级：menu bar 没抓到的/临时多做的，说一句补进实际（合并不覆盖）",
            "本地对比引擎 OverlapTitleComparer（时间重叠 × 标题相似），云端无关、可单测",
        ]),
        ChangelogEntry(version: "0.2", date: "2026-06", changes: [
            "M1：接入云端 Claude（Anthropic API）——自然语言 → 结构化日程 + 排程大脑排序/温和提示",
            "API key 存 Keychain；设置(⌘,) 可填 key / 选模型 / 开关云端；失败回退本地",
            "预留反思层（日记）数据 JournalEntry",
            "开发期可见报错：失败横幅 + 错误日志页（点版本号看本更新日志）",
        ]),
        ChangelogEntry(version: "0.1", date: "2026-06", changes: [
            "M0 骨架：分层架构（App / Models / Services 协议+实现 / Features / UseCases）",
            "SwiftData 数据模型（PlanDay / PlanBlock / CompletionLink / ExecutionSession / AppSettings）",
            "协议桩 + 假日历预览（FakeCalendarStore）：开发期不污染系统日历",
            "排程大脑接口（ScheduleParsing / PlanningEngine）+ 朴素本地兜底实现，空界面跑通",
        ]),
    ]
}
