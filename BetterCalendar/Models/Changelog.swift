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
        ChangelogEntry(version: "0.16.2", date: "2026-07", changes: [
            "术语零成本化（§5.9 原则落地）：「在途」→「长期任务」——名词只负责秒懂；气质词以后随皮肤系统回归",
        ]),
        ChangelogEntry(version: "0.16.1", date: "2026-07", changes: [
            "设置页分层：主页面只留常用项（API key、日历后端、日记隐私锁），AI 模型选择和提醒提前量收进「进阶设置」——新手打开不再眼花",
        ]),
        ChangelogEntry(version: "0.16", date: "2026-07", changes: [
            "排日程页改为「文件模型」（与 Jason 共同定稿）：看到的 = 已保存的计划 + 你未保存的修改；「确认写入」= 保存；「放弃修改」= 不保存",
            "打开 App 永远先显示已保存的计划；上次退出留有未保存修改时，顶部一行小字可「恢复 / 丢弃」（不弹窗打断）",
            "移除 0.15 的编辑自动保存——单一规则取代双轨制，改动是否生效一目了然",
        ]),
        ChangelogEntry(version: "0.15.3", date: "2026-07", changes: [
            "设置页 API key 新增「测试」按钮：一键验证 key 和所选模型是否可用（输入框有内容测输入框的，否则测已保存的）",
        ]),
        ChangelogEntry(version: "0.15.2", date: "2026-07", changes: [
            "修复：长输入（一天说很多件事+长期任务）解析失败——AI 回复上限从 2048 提到 6000 token，不再拦腰截断",
            "解析改宽容模式：个别条目格式异常只跳过该条，不再整包报废退回乱切草稿；截断/解码失败会记录原文便于排查",
        ]),
        ChangelogEntry(version: "0.15.1", date: "2026-07", changes: [
            "启动自愈：打开 App 时若日历里有今天的绿色计划、内部数据缺失（换设备/重装等），自动从日历重建——排日程页直接显示当天计划",
        ]),
        ChangelogEntry(version: "0.15", date: "2026-07", changes: [
            "已确认计划编辑即生效：改时间/标题/删块 0.8 秒后自动写回日历和数据库，不再需要点「确认写入」（新草稿仍需确认）",
            "绿色徽章实时显示「改动已自动保存 · 时间」",
        ]),
        ChangelogEntry(version: "0.14.1", date: "2026-07", changes: [
            "修复：过期的未确认草稿不再盖住「已确认计划」的自动显示（打开排日程页看不到当天计划的根因）",
            "草稿态新增「放弃草稿」：一键丢弃、回到已确认的计划",
        ]),
        ChangelogEntry(version: "0.14", date: "2026-07", changes: [
            "跨端日志：Mac 和 iPhone 的运行日志随 iCloud 同步汇总（保留 7 天）——开发者（Claude）可从 Mac 命令行直接查看双端内测日志，远程排障不再靠猜",
        ]),
        ChangelogEntry(version: "0.13.2", date: "2026-07", changes: [
            "iOS：草稿区新增「放大」按钮——全屏浏览/编辑/拖动排序日程块，改完点完成回来（小窗不再挤）",
        ]),
        ChangelogEntry(version: "0.13.1", date: "2026-07", changes: [
            "排程会看你的真实日历了：目标日已有的日程（其它日历的会议等）作为已占用时段，AI 自动避开",
            "目标日到期的提醒事项也会纳入考虑（不硬塞，只是知道）——真日历模式下生效",
        ]),
        ChangelogEntry(version: "0.13", date: "2026-07", changes: [
            "「AI 调整」现在记得你最初的要求：微调时不会违背原始约束（如娱乐时长下限、结束时间）",
            "修复：目标日锚定——排 5 号的日程不会再跑到 6 号（真实时间与目标日分开告知 AI）",
            "支持并行日程：明确说「这几件可以并行/同时做」时，AI 会把它们排成重叠时段",
        ]),
        ChangelogEntry(version: "0.12.4", date: "2026-07", changes: [
            "排日程草稿随时落盘：输入框文字和 AI 排出的未确认草稿逐次保存，崩溃/强退/重启后打开自动还原到之前的画面",
        ]),
        ChangelogEntry(version: "0.12.3", date: "2026-07", changes: [
            "「排今天」按钮文案随目标日变：排今天/明天/后天/昨天（更远显日期）",
            "AI 排出的草稿按时间从早到晚显示；跨午夜的凌晨块按次日日期垫底、不再窜到最前",
        ]),
        ChangelogEntry(version: "0.12.2", date: "2026-07", changes: [
            "「在途」累计投入（M10 完结）：抽屉里每件长线显示「已投入 X 小时」——只算做了多少，不算剩多少",
            "复盘页新增「长线推进」行：今天动过的在途 +今日投入（累计 N 小时），随分享小结一起见证积累",
        ]),
        ChangelogEntry(version: "0.12.1", date: "2026-07", changes: [
            "排程大脑会看「在途」了：排今天时若有空档，AI 从在途池挑 0–2 件建议排入（DDL 近的优先）",
            "建议块带 🗂 标记、删掉即今天不做——建议不是命令",
        ]),
        ChangelogEntry(version: "0.12", date: "2026-07", changes: [
            "新「在途」（M10 第一步）：远期 DDL 任务和长线作业有地方待了——说「下周五前交论文」会自动识别、确认时入池",
            "排日程页顶部收起一行「在途 N 件」，点开可 排进今天/做成/推一周/先放下；DDL 过了温和三选，不见红",
            "在途随 iCloud 跨端同步（⚠️ 需重新 Deploy CloudKit schema）",
        ]),
        ChangelogEntry(version: "0.11", date: "2026-07", changes: [
            "iOS 主屏小组件「今天」：正在做 / 接下来 / 今日做成 N 件（正反馈口径，不显完成率），执行动作后即时刷新",
            "iOS 控制中心控件：一键「完成当前 / 开始下一件」",
            "快捷指令请求改走 App Group（控制中心控件在扩展进程执行也能递到主 App）",
        ]),
        ChangelogEntry(version: "0.10", date: "2026-07", changes: [
            "新快捷指令「标记完成」：按任务名把今日某件事标为已完成（正在做的走正常完成、后台的收尾、其余按计划时段记实际）",
            "为 Claude Code 完成信号铺路：在快捷指令 App 包一层接收文本的指令后，命令行 shortcuts run 即可让 AI 干完活自动标完成",
        ]),
        ChangelogEntry(version: "0.9", date: "2026-07", changes: [
            "日记照片跨端同步：照片本体随 iCloud 同步（CKAsset），Mac 贴的图 iPhone 也能看到；旧照片自动迁移",
        ]),
        ChangelogEntry(version: "0.8.1", date: "2026-07", changes: [
            "日记隐私锁：设置里开启后，进日记页需 Face ID / Touch ID / 密码；退后台自动重新上锁",
        ]),
        ChangelogEntry(version: "0.8", date: "2026-07", changes: [
            "日记「往年今天」：有往年同月同日的日记时，顶部出现回顾卡片、点开重温（用得越久越有味道）",
            "日记一键导出 Markdown：全部条目（日期/心情/标签/正文）——macOS 存文件 / iOS 分享",
        ]),
        ChangelogEntry(version: "0.7.1", date: "2026-07", changes: [
            "macOS：番茄钟进行时温和提示可开系统专注模式（一键跳设置；macOS 无屏蔽 API 的替代方案）",
        ]),
        ChangelogEntry(version: "0.7", date: "2026-07", changes: [
            "执行会话开始落库（iCloud 同步）：每次完成/切走记 净时长·计时风格·番茄工作段数·休息次数——为日后趋势统计（正向口径）铺数据",
        ]),
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
