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
    static var description = IntentDescription("用一句自然语言安排今天；BetterCalendar 会打开排日程页并开始生成草稿。")
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
    static var description = IntentDescription("打开 BetterCalendar 的排日程页面。")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppIntentRequest.enqueue(.openSchedule)
        return .result()
    }
}

struct OpenTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "打开今天"
    static var description = IntentDescription("打开 BetterCalendar 的今天执行页面。")
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

struct StartTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "开始今天"
    static var description = IntentDescription("记录今天的实际开工时间，并按现在重排剩余日程。")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppIntentRequest.enqueue(.startToday)
        return .result()
    }
}

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
            intent: StartTodayIntent(),
            phrases: [
                "在 \(.applicationName) 开始今天",
                "用 \(.applicationName) 开始今天"
            ],
            shortTitle: "开始今天",
            systemImageName: "sunrise"
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
