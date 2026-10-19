//
//  StartTodayIntent.swift
//  BetterCalendar
//
//  Siri / Shortcuts entry points. Intents keep the work small: they enqueue a
//  request and open the app; BetterCalendarApp consumes the request with the
//  existing Router + ViewModel wiring.
//

import AppIntents

struct ArrangeTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "排今天"
    static var description = IntentDescription("把你想怎么过今天说给 BetterCalendar 智能体：打开 App 交给它，它提出的安排等你批准。")
    static var openAppWhenRun = true

    @Parameter(title: "今天安排", requestValueDialog: "今天想安排什么？")
    var planText: String?

    init() {}

    init(planText: String? = nil) {
        self.planText = planText
    }

    func perform() async throws -> some IntentResult {
        AppIntentRequest.enqueue(.arrangeToday, payload: planText)
        return .result()
    }
}

struct OpenScheduleIntent: AppIntent {
    static var title: LocalizedStringResource = "打开排日程"
    static var description = IntentDescription("打开 BetterCalendar 的今天页面。")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppIntentRequest.enqueue(.openSchedule)
        return .result()
    }
}

struct OpenTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "打开今天"
    static var description = IntentDescription("打开 BetterCalendar 的今天页面。")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppIntentRequest.enqueue(.openToday)
        return .result()
    }
}

struct OpenJournalIntent: AppIntent {
    static var title: LocalizedStringResource = "打开日记"
    static var description = IntentDescription("打开 BetterCalendar 的日记页面。")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppIntentRequest.enqueue(.openJournal)
        return .result()
    }
}

// StartTodayIntent 已退役（0.23 A，SPEC §11 ①）：首次开始任一事项即进实时模式，
// 「开始专注」（StartFocusIntent）语义完全覆盖，不需要两个入口。

struct StartFocusIntent: AppIntent {
    static var title: LocalizedStringResource = "开始专注"
    static var description = IntentDescription("打开今天，并开始下一件可做的任务。")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppIntentRequest.enqueue(.startFocus)
        return .result()
    }
}

struct CompleteCurrentIntent: AppIntent {
    static var title: LocalizedStringResource = "完成当前"
    static var description = IntentDescription("完成当前正在做的任务；如果没有进行中的任务，就开始下一件。")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppIntentRequest.enqueue(.completeCurrent)
        return .result()
    }
}

struct MarkDoneIntent: AppIntent {
    static var title: LocalizedStringResource = "标记完成"
    static var description = IntentDescription("按任务名把今日计划里的某件事标为已完成（记入实际）。可被快捷指令/自动化调用——例如 Claude Code 干完活时经 shortcuts 命令行标完成。")
    static var openAppWhenRun = true

    @Parameter(title: "任务名", requestValueDialog: "完成的是哪件事？")
    var taskTitle: String

    init() {}

    init(taskTitle: String) {
        self.taskTitle = taskTitle
    }

    func perform() async throws -> some IntentResult {
        AppIntentRequest.enqueue(.markDone, payload: taskTitle)
        return .result()
    }
}

struct OpenReviewIntent: AppIntent {
    static var title: LocalizedStringResource = "打开复盘"
    static var description = IntentDescription("打开今天的正反馈复盘。")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppIntentRequest.enqueue(.review)
        return .result()
    }
}

struct BetterCalendarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // 自动休息两枚（0.36.0，TestFlight 反馈#1b）：注册成 App Shortcuts=快捷指令 App 里**零配置就有**，
        // 建自动化时直接选现成动作——「一键添加自动化」系统做不到（个人自动化无编程创建 API），这是能给到的最少步数。
        AppShortcut(
            intent: StartAutoBreakIntent(),
            phrases: ["在 \(.applicationName) 开始自动休息"],
            shortTitle: "自动休息开始",
            systemImageName: "cup.and.saucer"
        )

        AppShortcut(
            intent: EndAutoBreakIntent(),
            phrases: ["在 \(.applicationName) 结束自动休息"],
            shortTitle: "自动休息结束",
            systemImageName: "cup.and.saucer.fill"
        )

        // W13 设备活动记录（实验）：给「App 打开 / 关闭」自动化用的两枚，零配置出现在快捷指令 App 里。
        // ⚠️ 系统上限：一个 App 最多 10 个 App Shortcut（加上这两枚共 9 个）。
        AppShortcut(
            intent: RecordAppOpenedIntent(),
            phrases: ["用 \(.applicationName) 记录 App 打开"],
            shortTitle: "记录 App 打开",
            systemImageName: "app.badge.checkmark"
        )

        AppShortcut(
            intent: RecordAppClosedIntent(),
            phrases: ["用 \(.applicationName) 记录 App 关闭"],
            shortTitle: "记录 App 关闭",
            systemImageName: "app.dashed"
        )

        AppShortcut(
            intent: ArrangeTodayIntent(),
            phrases: [
                "在 \(.applicationName) 排今天",
                "用 \(.applicationName) 安排今天"
            ],
            shortTitle: "排今天",
            systemImageName: "calendar.badge.plus"
        )

        AppShortcut(
            intent: StartFocusIntent(),
            phrases: [
                "在 \(.applicationName) 开始专注",
                "用 \(.applicationName) 开始下一件"
            ],
            shortTitle: "开始专注",
            systemImageName: "play.circle"
        )

        AppShortcut(
            intent: CompleteCurrentIntent(),
            phrases: [
                "在 \(.applicationName) 完成当前",
                "用 \(.applicationName) 完成这一件"
            ],
            shortTitle: "完成当前",
            systemImageName: "checkmark.circle"
        )

        AppShortcut(
            intent: MarkDoneIntent(),
            phrases: [
                "在 \(.applicationName) 标记完成",
                "用 \(.applicationName) 标记完成"
            ],
            shortTitle: "标记完成",
            systemImageName: "checkmark.seal"
        )

        AppShortcut(
            intent: OpenReviewIntent(),
            phrases: [
                "在 \(.applicationName) 打开复盘",
                "用 \(.applicationName) 看今天复盘"
            ],
            shortTitle: "打开复盘",
            systemImageName: "checkmark.seal"
        )
    }
}
