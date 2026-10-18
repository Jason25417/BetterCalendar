//
//  LocalProposalNotifier.swift
//  BetterCalendar
//
//  SPEC §19 B1：带「批准 / 拒绝」按钮的系统通知（Duo 式）。标题写是什么事，正文写改动前后 + 理由。
//  本机按提案内容生成通知（推送只负责唤醒），所以各端内容一致；决定后由 ProposalCenter 统一收起（B2）。
//  W10：第三种回应「回一句」（系统文本输入动作，iOS / macOS 都支持）；智能体填了备选方案时，每个方案一个按钮
//  （按本提案动态注册一个通知类别）——放不下时只留「查看全部方案」引导打开详情；预授权规则「做完告诉你」的结果通知（可撤销）。
//  W11：滑块和时间选择器放不进通知——带可调参数的提案用「按默认批准」+ 回一句 + 拒绝 +「打开调整」，正文写明默认值；
//  点通知本身打开卡片去调。备选方案的动态类别照旧，带参数的方案按钮写「（按默认）」。
//

import Foundation
import UserNotifications
import Observation

@MainActor final class LocalProposalNotifier: ProposalNotifying {
    static let category = "BC_PROPOSAL"
    static let approveAction = "BC_PROPOSAL_APPROVE"
    static let declineAction = "BC_PROPOSAL_DECLINE"
    static let openAction = "BC_PROPOSAL_OPEN"
    static let idPrefix = "bc.proposal."
    static let userInfoKey = "bcProposalId"
    // —— W10 ——
    static let replyAction = "BC_PROPOSAL_REPLY"
    /// 选方案按钮：后缀 = 方案序号（0 = 主方案）。
    static let pickPrefix = "BC_PROPOSAL_PICK."
    /// 有备选方案的提案各自一个类别（按钮名字就是方案名）。
    static let optionsCategoryPrefix = "BC_PROPOSAL_OPTS."
    static let resultCategory = "BC_PROPOSAL_RESULT"
    /// W11：带可调参数（没有备选）的提案类别：批准按钮写明「按默认批准」。
    static let parametersCategory = "BC_PROPOSAL_PARAMS"
    static let undoAction = "BC_PROPOSAL_UNDO"
    static let resultIdPrefix = "bc.proposal.result."
    static let resultUserInfoKey = "bcProposalResultId"
    /// 一条通知按「最多 4 个按钮」设计（系统展开后能列出的动作数有限，各平台不同；保守取 4）。
    static let maxActions = 4

    /// 通知上的回应（点通知本身 / 「查看详情」一律只打开，绝不当作批准）。
    enum Response: Equatable {
        case open
        case decide(ProposalDecision, choice: Int?)
        case reply(String)
        case undo
    }

    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    /// 与已有类别合并注册（setNotificationCategories 是整体替换，不能覆盖旧审批/提醒的类别）。
    static func registerCategories(center: UNUserNotificationCenter = .current()) async {
        let approve = UNNotificationAction(identifier: approveAction, title: "批准", options: [.authenticationRequired])
        let open = UNNotificationAction(identifier: openAction, title: "查看详情", options: [.foreground])
        let proposals = UNNotificationCategory(identifier: category, actions: [approve, replyButton, declineButton, open],
                                               intentIdentifiers: [], options: [])
        let undo = UNNotificationAction(identifier: undoAction, title: "撤销", options: [.authenticationRequired, .destructive])
        let result = UNNotificationCategory(identifier: resultCategory, actions: [undo], intentIdentifiers: [], options: [])
        await merge([proposals, result, parametersCategoryDefinition], center: center)
    }

    /// W11：按默认批准（同一个批准动作 id：解析出来就是不带数值的批准 = 默认值）+ 回一句 + 拒绝 + 打开调整。
    static var parametersCategoryDefinition: UNNotificationCategory {
        let approve = UNNotificationAction(identifier: approveAction, title: "按默认批准", options: [.authenticationRequired])
        let adjust = UNNotificationAction(identifier: openAction, title: "打开调整", options: [.foreground])
        return UNNotificationCategory(identifier: parametersCategory, actions: [approve, replyButton, declineButton, adjust],
                                      intentIdentifiers: [], options: [])
    }

    private static var replyButton: UNTextInputNotificationAction {
        UNTextInputNotificationAction(identifier: replyAction, title: "回一句", options: [.authenticationRequired],
                                      textInputButtonTitle: "发送", textInputPlaceholder: "比如「改成 9 点吧」")
    }
    private static var declineButton: UNNotificationAction {
        UNNotificationAction(identifier: declineAction, title: "拒绝", options: [.authenticationRequired, .destructive])
    }

    /// 有备选方案时的按钮：每个方案一个（「1. 挪到 9 点」）+ 回一句 + 拒绝；放不下（超过 maxActions）时
    /// 只留「查看全部 N 个方案」（打开详情去挑）+ 回一句 + 拒绝，正文里也写明。
    static func optionsFit(_ p: Proposal) -> Bool { p.options.count + 2 <= maxActions }

    static func optionsCategory(for p: Proposal) -> UNNotificationCategory {
        let picks: [UNNotificationAction] = optionsFit(p)
            ? p.options.map { UNNotificationAction(identifier: pickPrefix + String($0.index),
                                                   title: "\($0.index + 1). \($0.label)" + ($0.parameters.isEmpty ? "" : "（按默认）"),
                                                   options: [.authenticationRequired]) }
            : [UNNotificationAction(identifier: openAction, title: "查看全部 \(p.options.count) 个方案", options: [.foreground])]
        return UNNotificationCategory(identifier: categoryId(for: p), actions: picks + [replyButton, declineButton],
                                      intentIdentifiers: [], options: [])
    }

    static func categoryId(for p: Proposal) -> String {
        if p.hasAlternatives { return optionsCategoryPrefix + p.id.uuidString }
        return p.hasParameters ? parametersCategory : category
    }

    /// 与已有类别合并注册（整体替换语义：先读后写，不能覆盖旧审批/提醒的类别）。
    private static func merge(_ added: [UNNotificationCategory], removing: Set<String> = [], center: UNUserNotificationCenter) async {
        let ids = Set(added.map(\.identifier)).union(removing)
        var categories = await center.notificationCategories().filter { !ids.contains($0.identifier) }
        for c in added { categories.insert(c) }
        center.setNotificationCategories(categories)
    }

    static func request(for p: Proposal) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = (p.escalation != nil ? "【越级】" : "") + p.title
        content.subtitle = (p.experiment ? "测试 · " : "") + "截止 " + p.expiresAt.formatted(date: .omitted, time: .shortened)
        content.body = p.notificationBody
            + (p.hasAlternatives && !optionsFit(p) ? "\n有 \(p.options.count) 个方案：打开详情挑一个" : "")
        content.categoryIdentifier = categoryId(for: p)
        content.threadIdentifier = "bc.proposals"
        content.sound = .default
        content.userInfo = [userInfoKey: p.id.uuidString]
        return UNNotificationRequest(identifier: idPrefix + p.id.uuidString, content: content, trigger: nil)
    }

    /// 解析通知点击：批准/拒绝 → 带决定；点通知本身或「查看详情」→ 只打开详情，绝不当作批准。
    /// 本机通知（bcProposalId）或云端可见推送（B5，记录名）都能解析出提案 id。
    static func proposalId(from userInfo: [AnyHashable: Any]) -> UUID? {
        if let raw = userInfo[userInfoKey] as? String { return UUID(uuidString: raw) }
        return CloudKitProposalStore.proposalId(fromAlertPush: userInfo)
    }

    /// 是否是 B5 云端代发的可见推送（而非本机生成的通知）。
    static func isRemoteAlert(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[userInfoKey] == nil && CloudKitProposalStore.proposalId(fromAlertPush: userInfo) != nil
    }

    /// 只关心「批准 / 拒绝 / 打开」的旧入口（兼容）；回一句、选方案、撤销请用 response(...)。
    static func route(userInfo: [AnyHashable: Any], actionIdentifier: String) -> (id: UUID, decision: ProposalDecision?)? {
        switch response(userInfo: userInfo, actionIdentifier: actionIdentifier, typedText: nil) {
        case let (id, .decide(decision, nil))?: (id, decision)
        case let (id, .open)?: (id, nil)
        default: nil
        }
    }

    /// 解析通知上的回应。回一句时文字为空 = 只打开详情（不当作任何决定）。
    static func response(userInfo: [AnyHashable: Any], actionIdentifier: String, typedText: String?) -> (id: UUID, response: Response)? {
        if let raw = userInfo[resultUserInfoKey] as? String, let id = UUID(uuidString: raw) {
            switch actionIdentifier {
            case undoAction: return (id, .undo)
            case UNNotificationDefaultActionIdentifier: return (id, .open)
            default: return nil
            }
        }
        guard let id = proposalId(from: userInfo) else { return nil }
        switch actionIdentifier {
        case approveAction: return (id, .decide(.approve, choice: nil))
        case declineAction: return (id, .decide(.decline, choice: nil))
        case replyAction:
            let text = typedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (id, text.isEmpty ? .open : .reply(text))
        case openAction, UNNotificationDefaultActionIdentifier: return (id, .open)
        default:
            guard actionIdentifier.hasPrefix(pickPrefix), let i = Int(actionIdentifier.dropFirst(pickPrefix.count)), i >= 0 else { return nil }
            return (id, .decide(.approve, choice: i))
        }
    }

    func show(_ proposal: Proposal) async {
        if proposal.hasAlternatives { await Self.merge([Self.optionsCategory(for: proposal)], center: center) }
        do { try await center.add(Self.request(for: proposal)) } catch {
            DevLog.shared.error("多端审批", "审批通知发送失败：\(error.localizedDescription)")
        }
    }

    // MARK: W10 结果通知（预授权规则代你做完 / 自动执行失败）

    static func resultRequest(for p: Proposal) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        let failed = p.state == .failed
        content.title = (failed ? "按你的规则自动执行没成功：" : "已按你的规则做好：") + p.title
        var lines = p.chosen.changes.map(Proposal.line)
        if let note = p.resultNote { lines.append(note) }
        if let rule = p.preauth?.ruleLabel { lines.append("依据规则：" + rule) }
        if !failed, let hint = p.undoHint { lines.append(hint) }
        content.body = lines.joined(separator: "\n")
        if !failed, p.undoAction != nil { content.categoryIdentifier = resultCategory }
        content.threadIdentifier = "bc.proposals"
        content.userInfo = [resultUserInfoKey: p.id.uuidString]
        return UNNotificationRequest(identifier: resultIdPrefix + p.id.uuidString, content: content, trigger: nil)
    }

    func showResult(_ proposal: Proposal) async {
        do { try await center.add(Self.resultRequest(for: proposal)) } catch {
            DevLog.shared.error("预授权规则", "结果通知发送失败：\(error.localizedDescription)")
        }
    }

    func withdrawResult(_ id: UUID) async {
        center.removeDeliveredNotifications(withIdentifiers: [Self.resultIdPrefix + id.uuidString])
    }

    func shownResultIds() async -> Set<UUID> {
        Set(await center.deliveredNotifications().compactMap { n in
            let identifier = n.request.identifier
            return identifier.hasPrefix(Self.resultIdPrefix) ? UUID(uuidString: String(identifier.dropFirst(Self.resultIdPrefix.count))) : nil
        })
    }

    func withdraw(_ id: UUID) async {
        let identifier = Self.idPrefix + id.uuidString
        // 云端代发的可见推送（B5）标识由系统生成，按载荷里的记录名找到再收起。
        let remote = await center.deliveredNotifications()
            .filter { Self.isRemoteAlert($0.request.content.userInfo) && Self.proposalId(from: $0.request.content.userInfo) == id }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: [identifier] + remote)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        // 备选方案的动态类别随通知一起收起（不让类别越堆越多）。
        let dynamic = Self.optionsCategoryPrefix + id.uuidString
        if await center.notificationCategories().contains(where: { $0.identifier == dynamic }) {
            await Self.merge([], removing: [dynamic], center: center)
        }
    }

    /// 本机已挂着通知的提案：本机生成的 + 云端代发的（避免同一提案弹两条）。
    func shownIds() async -> Set<UUID> {
        let delivered = await center.deliveredNotifications()
        let pending = await center.pendingNotificationRequests()
        let local = (delivered.map(\.request.identifier) + pending.map(\.identifier)).compactMap { identifier in
            identifier.hasPrefix(Self.idPrefix) ? UUID(uuidString: String(identifier.dropFirst(Self.idPrefix.count))) : nil
        }
        let remote = delivered.compactMap { Self.isRemoteAlert($0.request.content.userInfo) ? Self.proposalId(from: $0.request.content.userInfo) : nil }
        return Set(local + remote)
    }

    /// 前台去重：本机已为同一提案挂了通知时，云端代发的那条不再展示。
    func hasLocalNotification(for id: UUID) async -> Bool {
        await center.deliveredNotifications().contains { $0.request.identifier == Self.idPrefix + id.uuidString }
    }

    func permission() async -> Bool? {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        case .denied: false
        default: nil
        }
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
}

/// 推送唤醒的接缝：AppDelegate 收到本 zone 的推送后调用；由组装点挂上 ProposalCenter.refresh。
@MainActor enum ProposalWake {
    static var onPush: (() async -> Void)?
}

/// B5 可见推送订阅的读写缝（生产 = CloudKitProposalStore；测试 = 内存假实现）。
nonisolated protocol ProposalAlertPushing: Sendable {
    func isAlertPushEnabled() async throws -> Bool
    func setAlertPush(enabled: Bool) async throws
}
extension CloudKitProposalStore: ProposalAlertPushing {}

/// B5 可见推送开关（实验；W8 起你没手动关过就默认开）。订阅存在 iCloud 账户里：一端打开，所有设备生效；状态以云端为准。
@MainActor @Observable final class ProposalAlertPushControl {
    static let key = "approvals.alertPush.enabled"
    /// W8：用户**手动关过**的记号（只有面板上亲手关掉才写；亲手打开时清掉）。随设置同步——订阅属于 iCloud 账户、
    /// 全设备生效，iPhone 上关了，Mac 启动时不能又自动打开。
    static let userDisabledKey = "approvals.alertPush.userDisabled"
    private(set) var enabled: Bool
    private(set) var lastError: String?
    private let store: any ProposalAlertPushing
    private let defaults: UserDefaults
    init(store: any ProposalAlertPushing, defaults: UserDefaults = .standard) {
        self.store = store; self.defaults = defaults
        enabled = defaults.bool(forKey: Self.key)
    }
    /// 从云端读真实状态（其他设备可能已切换过）。
    func reload() async {
        do { enabled = try await store.isAlertPushEnabled(); defaults.set(enabled, forKey: Self.key); lastError = nil }
        catch { lastError = "读取推送状态失败：\(error.localizedDescription)" }
    }

    /// byUser=false 只用于启动时的默认打开（不改「手动关过」记号）。
    func set(_ on: Bool, byUser: Bool = true) async {
        do {
            try await store.setAlertPush(enabled: on)
            enabled = on; lastError = nil
            defaults.set(on, forKey: Self.key)
            if byUser {
                if on { defaults.removeObject(forKey: Self.userDisabledKey) } else { defaults.set(true, forKey: Self.userDisabledKey) }
            }
            DevLog.shared.info("多端审批", "App 关闭时推送（实验）已\(on ? "开启" : "关闭")" + (byUser ? "" : "（默认打开）"))
        } catch {
            lastError = "切换失败：\(error.localizedDescription)"
            DevLog.shared.error("多端审批", lastError!)
        }
    }

    /// W8（Jason 2026-10-18）：B5 默认开——App 启动时，若你从没手动关过，就自动打开订阅。
    /// 先读云端真实状态（已开 = 什么都不做）；读失败或打开失败照常可见（lastError + DevLog），下次启动再试。
    func autoEnableIfNeverDisabled() async {
        guard ExperimentDefaults.neverSet(Self.userDisabledKey, in: defaults) else { return }
        await reload()
        if let lastError {
            DevLog.shared.error("多端审批", "默认打开 iCloud 直接推送前读取状态失败：\(lastError)")
            return
        }
        guard !enabled else { return }
        await set(true, byUser: false)
    }
}
