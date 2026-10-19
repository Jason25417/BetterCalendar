//
//  FeatureRegistry.swift
//  BetterCalendar
//
//  W21 功能使用探针（2026-10-19 Jason 提出）：用户看得见的功能登记表——每个功能一个**稳定 id**（rawValue，
//  写进本机记录与给智能体的摘要，改了就对不上历史，只能加不能改名）+ 一句中文名 + 所属区域 + 「怎么算看见过」。
//  用途：U2「视觉音量 ∝ 实测频率」的依据；智能体偶尔温和提议（U4：可忽略、不纠缠）的依据。
//  开发期界面（试验台 / 试衣间 / 开发者选项里的东西）不登记（U13 豁免，也不该影响音量判断）。
//

import Foundation

/// 「看见过」怎么算（解读层据此决定能不能说「可能不知道有这个功能」）。
nonisolated enum FeatureExposure: Sendable, Equatable {
    /// 自己记 seen（功能出现在屏幕上时记，节流）。
    case direct
    /// 常驻在某个页面 / 面板上：那个页面被看见 = 它被看见。
    case onPage(FeatureID)
    /// 收在某个菜单 / 折叠区 / 详情页里：父级被看见 ≠ 它被看见（解读时措辞是「可能不知道，它收在 X 里」）。
    case inMenu(FeatureID)
    /// W26：没有按钮的手势（在时间轴上拖 / 拉边）：所在处被看见 ≠ 知道能这么做（解读时措辞是「可能不知道，它是 X 上的手势」）。
    case gesture(FeatureID)
    /// 没有「看见」这回事（通知按钮、快捷指令、控件、自动行为）：只按用过 / 撤销 / 出错解读。
    case none
}

nonisolated enum FeatureID: String, CaseIterable, Codable, Sendable {
    // MARK: 今天页（改 / 删 / 加记在 HomeViewModel 的写入路径，卡片列表和时间轴两种视图都记；
    // 「拖动」分两条：today.drag = 卡片列表里拖排序，today.axis.drag = 时间轴上拖时间。W26 补登记了时间轴、
    // 提示条（主动建议 / 收尾卡 / 晨间摘要）与「这一天」菜单里的导出 / 按日历更新——每个 id 都有调用点，有测试守着。）
    case todayPage = "today.page"
    case todayDaySwitch = "today.daySwitch"
    case todayDrag = "today.drag"
    case todayEdit = "today.edit"
    case todayDelete = "today.delete"
    case todayAdd = "today.add"
    case todaySayToAgent = "today.sayToAgent"
    case todayLoose = "today.loose"
    case todayTraceReview = "today.traceReview"
    // W26：时间轴（今天页默认视图）
    case todayAxis = "today.axis"
    case todayAxisDrag = "today.axis.drag"
    case todayAxisResize = "today.axis.resize"
    case todayAxisEdit = "today.axis.edit"
    case todayAxisBackToNow = "today.axis.backToNow"
    case todayAxisDayJump = "today.axis.dayJump"
    // W26：今天页的提示条与「这一天」菜单
    case todaySuggestion = "today.suggestion"
    case todayWrapUpCard = "today.wrapUpCard"
    case todayMorningBrief = "today.morningBrief"
    case todayExportICS = "today.exportICS"
    case todayUpdateDoneFromCalendar = "today.updateDoneFromCalendar"

    // MARK: 现在 / 下一件（今天页顶部与 Mac 菜单栏弹窗共用 ExecutionPanel；detail 记在哪个界面）
    case nowNextPanel = "nowNext.panel"
    case nowNextStart = "nowNext.start"
    case nowNextFinish = "nowNext.finish"
    case nowNextSwitch = "nowNext.switch"
    case nowNextParallel = "nowNext.parallel"
    case nowNextBackgroundFinish = "nowNext.backgroundFinish"
    case nowNextBreak = "nowNext.break"
    case nowNextTiming = "nowNext.timing"
    case nowNextAdHoc = "nowNext.adHoc"
    case nowNextPomodoroStep = "nowNext.pomodoroStep"
    case nowNextOpenJournal = "nowNext.openJournal"

    // MARK: 智能体页 / 对话
    case agentPage = "agent.page"
    case agentChatSend = "agent.chat.send"
    case agentChatRetry = "agent.chat.retry"

    // MARK: 提案卡（智能体页置顶、对话气泡、设置里的审批记录共用一张卡）
    case proposalCard = "proposal.card"
    case proposalApprove = "proposal.approve"
    case proposalDecline = "proposal.decline"
    case proposalReply = "proposal.reply"
    case proposalTune = "proposal.tune"
    case proposalChooseOption = "proposal.chooseOption"
    case proposalRememberRule = "proposal.rememberRule"
    case proposalUndo = "proposal.undo"

    // MARK: 长期页
    case longtermPage = "longterm.page"
    case longtermSay = "longterm.say"
    case longtermAddManual = "longterm.addManual"
    case longtermTodoAdd = "longterm.todoAdd"
    case longtermTodoToToday = "longterm.todoToToday"
    case longtermTodoDiscard = "longterm.todoDiscard"
    case longtermTaskToToday = "longterm.taskToToday"
    case longtermDetail = "longterm.detail"
    case longtermCheckpoint = "longterm.checkpoint"
    case longtermShelve = "longterm.shelve"
    case longtermComplete = "longterm.complete"
    case longtermUnshelve = "longterm.unshelve"
    case longtermReopen = "longterm.reopen"

    // MARK: 日记页
    case journalPage = "journal.page"
    case journalWrite = "journal.write"
    case journalReviewNow = "journal.reviewNow"
    case journalAutoJournal = "journal.autoJournal"
    case journalWrapUp = "journal.wrapUp"
    case journalPlanTomorrow = "journal.planTomorrow"
    case journalExport = "journal.export"
    case journalAchievements = "journal.achievements"
    case journalHistory = "journal.history"

    // MARK: 设置（只登记关键设置；改值 = 用过）
    case settingsPage = "settings.page"
    case settingsApprovalRecords = "settings.approvalRecords"
    case settingsEveningReview = "settings.eveningReview"
    case settingsCloudBrain = "settings.cloudBrain"
    case settingsFeedback = "settings.feedback"
    case settingsJournalLock = "settings.journalLock"
    case settingsRoutines = "settings.routines"
    case settingsAdvanced = "settings.advanced"
    case settingsDistraction = "settings.distraction"
    case settingsFocusFollow = "settings.focusFollow"
    case settingsWindDown = "settings.windDown"
    case settingsPushIntensity = "settings.pushIntensity"
    case settingsSkin = "settings.skin"
    case settingsBusyCalendars = "settings.busyCalendars"

    // MARK: 通知上的动作
    case notificationMorning = "notification.morning"
    case notificationEvening = "notification.evening"
    case notificationProposalOpen = "notification.proposal.open"
    case notificationProposalApprove = "notification.proposal.approve"
    case notificationProposalDecline = "notification.proposal.decline"
    case notificationProposalReply = "notification.proposal.reply"
    case notificationProposalUndo = "notification.proposal.undo"
    case notificationChatOpen = "notification.chat.open"
    case notificationChatReply = "notification.chat.reply"
    case notificationMessageOpen = "notification.message.open"
    case notificationMessageReact = "notification.message.react"

    // MARK: 菜单栏（Mac）
    case menubarPopover = "menubar.popover"
    case menubarOpenMain = "menubar.openMain"

    // MARK: 快捷指令 / 控制中心控件
    case intentArrangeToday = "intent.arrangeToday"
    case intentOpenToday = "intent.openToday"
    case intentOpenJournal = "intent.openJournal"
    case intentStartFocus = "intent.startFocus"
    case intentCompleteCurrent = "intent.completeCurrent"
    case intentMarkDone = "intent.markDone"
    case intentReview = "intent.review"
    case controlCompleteCurrent = "control.completeCurrent"

    // MARK: 自动行为（只记被你撤销的次数：撤销多 = 结果不合预期）
    case autoAdjust = "auto.adjust"
    case autoBreak = "auto.break"

    /// 短中文名（给人看、给智能体看）。
    var label: String {
        switch self {
        case .todayPage: "今天页"
        case .todayDaySwitch: "切换日期（今天页顶部的日期条）"
        case .todayDrag: "拖动调整时间线（卡片列表）"
        case .todayEdit: "直接改块（时间 / 标题 / 属性）"
        case .todayDelete: "删除一块"
        case .todayAdd: "时间线「加一项」"
        case .todaySayToAgent: "今天页「跟智能体说一句」"
        case .todayLoose: "这天松散一下"
        case .todayTraceReview: "查看 / 撤销自动调整"
        case .todayAxis: "今天页时间轴"
        case .todayAxisDrag: "在时间轴上拖动改时间（含拖到别的日子）"
        case .todayAxisResize: "在时间轴上拉底边改时长"
        case .todayAxisEdit: "点时间轴上的块打开编辑"
        case .todayAxisBackToNow: "时间轴「回到现在」"
        case .todayAxisDayJump: "时间轴顶上的日子条（跳到那天）"
        case .todaySuggestion: "主动建议条（排进今天 / 先放下）"
        case .todayWrapUpCard: "收尾卡（进入收尾）"
        case .todayMorningBrief: "晨间摘要（昨天留下的待办「排今天」）"
        case .todayExportICS: "导出 ICS（「这一天」菜单）"
        case .todayUpdateDoneFromCalendar: "按系统日历更新今天做成的事（「这一天」菜单）"
        case .nowNextPanel: "现在 / 下一件面板"
        case .nowNextStart: "开始这件 / 开始下一件"
        case .nowNextFinish: "完成这件"
        case .nowNextSwitch: "换一件"
        case .nowNextParallel: "同时做"
        case .nowNextBackgroundFinish: "完成后台并行的事"
        case .nowNextBreak: "休息"
        case .nowNextTiming: "改计时方式（轻计时 / 不计时 / 番茄）"
        case .nowNextAdHoc: "新事项（计划外当场开始）"
        case .nowNextPomodoroStep: "番茄段间（再来一段 / 回到专注 / 继续计时）"
        case .nowNextOpenJournal: "回看今天"
        case .agentPage: "智能体页"
        case .agentChatSend: "给智能体发消息"
        case .agentChatRetry: "重发没发出去的消息"
        case .proposalCard: "提案卡"
        case .proposalApprove: "同意提案"
        case .proposalDecline: "拒绝提案"
        case .proposalReply: "对提案回一句"
        case .proposalTune: "调提案里的数值"
        case .proposalChooseOption: "在备选方案里选一个"
        case .proposalRememberRule: "以后同类…（预授权规则）"
        case .proposalUndo: "撤销已执行的提案"
        case .longtermPage: "长期页"
        case .longtermSay: "长期页「说一句」"
        case .longtermAddManual: "手动加一件长期的事"
        case .longtermTodoAdd: "记一件想做的小事"
        case .longtermTodoToToday: "待办「排今天」"
        case .longtermTodoDiscard: "丢弃待办"
        case .longtermTaskToToday: "长期事项「排进今天」"
        case .longtermDetail: "长期事项详情"
        case .longtermCheckpoint: "勾选阶段"
        case .longtermShelve: "先放下"
        case .longtermComplete: "长期事项做成了"
        case .longtermUnshelve: "捞回来"
        case .longtermReopen: "拿回来（做成了的）"
        case .journalPage: "日记页"
        case .journalWrite: "写今天的日记"
        case .journalReviewNow: "现在就回看"
        case .journalAutoJournal: "自动日记"
        case .journalWrapUp: "收尾流程"
        case .journalPlanTomorrow: "顺手排明天"
        case .journalExport: "导出日记"
        case .journalAchievements: "成就"
        case .journalHistory: "翻看过去的日记"
        case .settingsPage: "设置"
        case .settingsApprovalRecords: "审批记录与规则"
        case .settingsEveningReview: "晚间复盘设置"
        case .settingsCloudBrain: "云端排程大脑"
        case .settingsFeedback: "发送反馈"
        case .settingsJournalLock: "日记隐私锁"
        case .settingsRoutines: "例行"
        case .settingsAdvanced: "进阶设置"
        case .settingsDistraction: "自动休息感知"
        case .settingsFocusFollow: "多端跟随专注"
        case .settingsWindDown: "最晚工作到几点"
        case .settingsPushIntensity: "主动建议强度"
        case .settingsSkin: "皮肤"
        case .settingsBusyCalendars: "排布时当作已占用的日历"
        case .notificationMorning: "早通知"
        case .notificationEvening: "晚通知"
        case .notificationProposalOpen: "提案通知：查看详情"
        case .notificationProposalApprove: "提案通知：批准"
        case .notificationProposalDecline: "提案通知：拒绝"
        case .notificationProposalReply: "提案通知：回一句"
        case .notificationProposalUndo: "提案通知：撤销"
        case .notificationChatOpen: "对话通知：打开"
        case .notificationChatReply: "对话通知：直接回复"
        case .notificationMessageOpen: "智能体消息通知：打开"
        case .notificationMessageReact: "智能体消息通知：知道了 / 别再提"
        case .menubarPopover: "菜单栏弹窗"
        case .menubarOpenMain: "菜单栏右键「打开主窗口」"
        case .intentArrangeToday: "快捷指令：排今天"
        case .intentOpenToday: "快捷指令：打开今天"
        case .intentOpenJournal: "快捷指令：打开日记"
        case .intentStartFocus: "快捷指令：开始下一件"
        case .intentCompleteCurrent: "快捷指令：完成当前"
        case .intentMarkDone: "快捷指令：按标题标完成"
        case .intentReview: "快捷指令：今日复盘"
        case .controlCompleteCurrent: "控制中心控件：完成 / 下一件"
        case .autoAdjust: "自动调整计划"
        case .autoBreak: "自动休息（感知到走开）"
        }
    }

    /// 所属区域（只用于分组显示）。
    var area: String {
        switch rawValue.split(separator: ".").first.map(String.init) ?? "" {
        case "today": "今天页"
        case "nowNext": "现在 / 下一件"
        case "agent": "智能体"
        case "proposal": "提案卡"
        case "longterm": "长期"
        case "journal": "日记"
        case "settings": "设置"
        case "notification": "通知"
        case "menubar": "菜单栏"
        case "intent", "control": "快捷指令与控件"
        case "auto": "自动行为"
        default: "其它"
        }
    }

    var exposure: FeatureExposure {
        switch self {
        case .todayPage: .direct
        case .todayTraceReview: .none   // 「查看 / 撤销」打开的清单里记
        case .todayDaySwitch, .todaySayToAgent, .todayAdd: .onPage(.todayPage)
        // 时间线有 ≥2 块时它在眼前；W23 重做时间线后由协调者补 seen（在那之前按今天页算）
        case .todayDrag, .todayEdit: .onPage(.todayPage)
        case .todayDelete, .todayLoose: .inMenu(.todayPage)
        // 时间轴：轴本身出现即记 seen；拖 / 拉边是没有按钮的手势；点块编辑、日子条常驻在轴上；
        // 「回到现在」只在闸门滚出视口时出现（出现时自己记 seen）
        case .todayAxis, .todayAxisBackToNow: .direct
        case .todayAxisDrag, .todayAxisResize: .gesture(.todayAxis)
        case .todayAxisEdit, .todayAxisDayJump: .onPage(.todayAxis)
        // 提示条只在条件满足时出现，出现时自己记 seen；点掉 / 别再提 / 先不收尾不算「用过」（那是「不需要」的信号）
        case .todaySuggestion, .todayWrapUpCard, .todayMorningBrief: .direct
        case .todayExportICS, .todayUpdateDoneFromCalendar: .inMenu(.todayPage)
        case .nowNextPanel: .direct
        case .nowNextStart, .nowNextFinish, .nowNextSwitch, .nowNextParallel, .nowNextBreak, .nowNextTiming, .nowNextAdHoc:
            .onPage(.nowNextPanel)
        case .nowNextBackgroundFinish, .nowNextPomodoroStep, .nowNextOpenJournal: .none   // 只在特定状态出现
        case .agentPage: .direct
        case .agentChatSend: .onPage(.agentPage)
        case .agentChatRetry: .none
        case .proposalCard, .proposalTune, .proposalChooseOption, .proposalUndo: .direct
        case .proposalApprove, .proposalDecline, .proposalReply, .proposalRememberRule: .onPage(.proposalCard)
        case .longtermPage: .direct
        case .longtermSay, .longtermAddManual, .longtermTodoAdd, .longtermTodoToToday, .longtermTodoDiscard,
             .longtermTaskToToday, .longtermDetail: .onPage(.longtermPage)
        case .longtermCheckpoint, .longtermShelve, .longtermComplete: .inMenu(.longtermPage)
        case .longtermUnshelve, .longtermReopen: .none
        case .journalPage: .direct
        case .journalWrite, .journalReviewNow, .journalExport, .journalAchievements, .journalHistory: .onPage(.journalPage)
        case .journalAutoJournal, .journalPlanTomorrow: .direct
        case .journalWrapUp: .none
        case .settingsPage: .direct
        case .settingsApprovalRecords, .settingsEveningReview, .settingsCloudBrain, .settingsFeedback, .settingsJournalLock,
             .settingsRoutines, .settingsAdvanced: .onPage(.settingsPage)
        case .settingsDistraction, .settingsFocusFollow, .settingsWindDown, .settingsPushIntensity, .settingsSkin,
             .settingsBusyCalendars: .inMenu(.settingsAdvanced)
        case .notificationMorning, .notificationEvening, .notificationProposalOpen, .notificationProposalApprove,
             .notificationProposalDecline, .notificationProposalReply, .notificationProposalUndo, .notificationChatOpen,
             .notificationChatReply, .notificationMessageOpen, .notificationMessageReact: .none
        case .menubarPopover, .menubarOpenMain: .none
        case .intentArrangeToday, .intentOpenToday, .intentOpenJournal, .intentStartFocus, .intentCompleteCurrent,
             .intentMarkDone, .intentReview, .controlCompleteCurrent: .none
        case .autoAdjust, .autoBreak: .none
        }
    }

    /// 页面 / 面板本身（只记 seen，是别的功能的「所在处」）：解读层只对它说「可能不知道」，不说「不需要」。
    var isSurface: Bool {
        [.todayPage, .todayAxis, .nowNextPanel, .agentPage, .proposalCard, .longtermPage, .journalPage, .settingsPage].contains(self)
    }

    /// 自动行为：「用过」不由你发起，只看撤销（解读层不对它做「没用过」类推断）。
    var isAutomatic: Bool { area == "自动行为" }

    /// 从快捷指令请求映射（AppIntentRequest.rawValue → 功能）。openSchedule 与 openToday 是同一件事。
    static func intent(_ raw: String, source: String?) -> FeatureID? {
        if source == "control" { return raw == "completeCurrent" ? .controlCompleteCurrent : nil }
        switch raw {
        case "arrangeToday": return .intentArrangeToday
        case "openSchedule", "openToday": return .intentOpenToday
        case "openJournal": return .intentOpenJournal
        case "startFocus": return .intentStartFocus
        case "completeCurrent": return .intentCompleteCurrent
        case "markDone": return .intentMarkDone
        case "review": return .intentReview
        default: return nil
        }
    }
}
