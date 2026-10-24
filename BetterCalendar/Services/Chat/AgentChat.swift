//
//  AgentChat.swift
//  BetterCalendar
//
//  SPEC §19 A1：在 iPhone / Mac 上随口跟 BetterCalendar 智能体说话。
//  一条对话 = iCloud 私有库（与提案同分区 BCApprovals）里的一条 BCChatMessage 记录，各端看到同一份：
//    你说一句（任一端）→ 存 iCloud → Mac 端桥接取走、写成 user_message 事件唤醒智能体（标记「已转交」）
//    → 智能体用 reply_jason 回复 → Mac 导入回复存 iCloud → 各端显示（按打扰规则决定是否弹通知）。
//  智能体在对话里提出的改动以卡片呈现，卡片只存提案 id、状态一律读 ProposalCenter（B3：同一件事的第三个入口）。
//  F1 晚间复盘也走这里（kind = eveningReview）。
//

import CloudKit
import Foundation
import Observation

nonisolated struct AgentChatMessage: Identifiable, Codable, Equatable, Sendable {
    enum Author: String, Codable, Sendable { case user, agent }
    /// chat = 普通对话；eveningReview = F1 晚间复盘（智能体写「今天做成了什么」）。
    enum Kind: String, Codable, Sendable, CaseIterable { case chat, eveningReview }
    enum Delivery: String, Codable, Sendable { case delivered, suppressed }

    var id: UUID
    var createdAt: Date
    var author: Author
    /// 你说话的那台设备 / 导入智能体回复的那台 Mac。
    var deviceId: String
    var deviceLabel: String
    var text: String
    var kind: Kind = .chat
    /// 智能体回复的是哪一条你的消息；你的消息则指向你接着说的那条智能体消息（如复盘后补一句）。
    var replyTo: UUID?
    /// 对话里的提案卡片：只存 id，状态读 ProposalCenter（与通知、面板同一份）。
    var proposalIds: [UUID] = []
    /// 引出它的事件 id（智能体侧上下级关系）。
    var parentRef: String?
    /// W10：你这句话是在回某个提案（审批的第三种回应）；Mac 桥接写 user_message 时带上 inReplyToProposal。
    var inReplyToProposal: UUID? = nil
    // —— 你的消息：Mac 桥接转交给智能体的回执 ——
    var forwardedAt: Date?
    var forwardedByDeviceId: String?
    /// W35：谁接手、为什么（如「iPhone 没接上（等了 20 秒），由 Mac 回复」）；nil = 正常接手。只在 JSON 载荷里，不改 CloudKit schema。
    var forwardedNote: String? = nil
    /// W36：你发的图片 / 文件（元数据；本体在 ChatAttachmentStore，经 iCloud 资源字段同步）。nil = 没有。
    var attachments: [ChatAttachment]? = nil
    /// W40：智能体这句话用到的网页来源（默认收起，点「来源」才展开）。只在 JSON 载荷里，不改 CloudKit schema。nil = 没有。
    var sources: [ChatSource]? = nil
    // —— 智能体的消息：是否弹通知（Mac 导入时按打扰规则决定一次，各端照办）——
    var delivery: Delivery?
    var suppressReason: String?
}

/// 智能体回复（桥接文件 chat/<uuid>.json 解析后）。
/// W40：一条网页来源（智能体用 search_internet / read_webpage 查到、回复里引用的）。
nonisolated struct ChatSource: Codable, Equatable, Sendable, Hashable {
    var title: String
    var url: String
}

nonisolated struct AgentChatReplyDraft: Sendable, Equatable {
    var id: UUID
    var text: String
    var kind: AgentChatMessage.Kind = .chat
    var replyTo: UUID?
    var proposalIds: [UUID] = []
    var parentRef: String?
    /// W20：留底里写哪个实现说的（nil = 经桥接的 Claude Code，沿用「BetterCalendar 智能体」）。
    var originLabel: String? = nil
    /// W40：这句话用到的网页来源。
    var sources: [ChatSource] = []
}

nonisolated protocol AgentChatTransport: Sendable {
    func post(_ message: AgentChatMessage) async throws
    func fetchRecent() async throws -> [AgentChatMessage]
    func save(_ message: AgentChatMessage) async throws
    /// W35：认领你的一句话交给某台设备的智能体——先到先得（iCloud 条件写），两台设备不会都回。
    func claim(_ id: UUID, deviceId: String, note: String?, at: Date) async throws -> AgentChatClaim
}

nonisolated enum AgentChatClaim: Equatable, Sendable {
    /// 本机认领成功（返回写好回执的那份）。
    case won(AgentChatMessage)
    /// 已被认领（可能就是本机之前认领的）。
    case taken(AgentChatMessage)
}

extension AgentChatTransport {
    /// 测试替身的缺省实现（不是原子的；真实现见 CloudKitAgentChatStore / InMemoryAgentChatTransport）。
    func claim(_ id: UUID, deviceId: String, note: String?, at: Date) async throws -> AgentChatClaim {
        guard var m = try await fetchRecent().first(where: { $0.id == id }) else { throw URLError(.fileDoesNotExist) }
        if m.forwardedAt != nil { return .taken(m) }
        m.forwardedAt = at; m.forwardedByDeviceId = deviceId; m.forwardedNote = note
        try await save(m)
        return .won(m)
    }
}

/// 测试与 test host 用：两个 AgentChatCenter 共用一个实例 = 模拟两台设备经 iCloud 中转。
actor InMemoryAgentChatTransport: AgentChatTransport {
    private var store: [UUID: AgentChatMessage] = [:]
    var failNextPosts = 0
    func setFailNextPosts(_ n: Int) { failNextPosts = n }
    func post(_ message: AgentChatMessage) async throws {
        if failNextPosts > 0 { failNextPosts -= 1; throw URLError(.notConnectedToInternet) }
        store[message.id] = message
    }
    func fetchRecent() async throws -> [AgentChatMessage] { store.values.sorted { $0.createdAt < $1.createdAt } }
    func save(_ message: AgentChatMessage) async throws { store[message.id] = message }
    func claim(_ id: UUID, deviceId: String, note: String?, at: Date) async throws -> AgentChatClaim {
        guard var m = store[id] else { throw URLError(.fileDoesNotExist) }
        if m.forwardedAt != nil { return .taken(m) }
        m.forwardedAt = at; m.forwardedByDeviceId = deviceId; m.forwardedNote = note
        store[id] = m
        return .won(m)
    }
}

/// 与提案同一个 iCloud 私有分区（BCApprovals），记录类型 BCChatMessage。整条消息以 JSON 存 payload（唯一真相），
/// author/text/kind/createdAtLocal 镜像成独立字段便于排查。读取走分区增量变更（不依赖查询索引）。
actor CloudKitAgentChatStore: AgentChatTransport {
    static let recordType = "BCChatMessage"
    private let db: CKDatabase
    private var known: [CKRecord.ID: CKRecord] = [:]
    private var changeToken: CKServerChangeToken?
    private var zoneReady = false

    init(containerIdentifier: String = AppChannel.current.cloudKitContainerID) {
        db = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    private func recordID(_ id: UUID) -> CKRecord.ID { CKRecord.ID(recordName: "chat-" + id.uuidString, zoneID: CloudKitProposalStore.zoneID) }

    private func encode(_ m: AgentChatMessage, into r: CKRecord) throws {
        r["payload"] = String(decoding: try JSONEncoder().encode(m), as: UTF8.self) as CKRecordValue
        r["author"] = m.author.rawValue as CKRecordValue
        r["text"] = m.text as CKRecordValue
        r["kind"] = m.kind.rawValue as CKRecordValue
        r["createdAtLocal"] = m.createdAt as CKRecordValue
    }

    private func decode(_ r: CKRecord) -> AgentChatMessage? {
        guard r.recordType == Self.recordType, let raw = r["payload"] as? String,
              let m = try? JSONDecoder().decode(AgentChatMessage.self, from: Data(raw.utf8)) else { return nil }
        if let files = m.attachments, let assets = r["files"] as? [CKAsset] {   // W36：别的设备发的附件拷进本机
            for (a, asset) in zip(files, assets) { if let url = asset.fileURL { ChatAttachmentStore.ingest(a, from: url) } }
        }
        return m
    }

    /// iPhone 可能比任何提案更早发第一句话：分区不存在就先建（幂等）。
    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: CloudKitProposalStore.zoneID)], deleting: [])
        zoneReady = true
    }

    func post(_ message: AgentChatMessage) async throws {
        try await ensureZone()
        let r = CKRecord(recordType: Self.recordType, recordID: recordID(message.id))
        try encode(message, into: r)
        // W36：附件本体只在新建时上传一次（之后的回执 / 认领只改载荷，不重传）
        if let files = message.attachments, !files.isEmpty {
            r["files"] = files.map { CKAsset(fileURL: ChatAttachmentStore.url(for: $0)) } as CKRecordValue
        }
        known[r.recordID] = try await db.save(r)
    }

    func fetchRecent() async throws -> [AgentChatMessage] {
        var more = true
        while more {
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await db.recordZoneChanges(inZoneWith: CloudKitProposalStore.zoneID, since: changeToken)
            } catch let error as CKError where error.code == .changeTokenExpired {
                changeToken = nil; known = [:]; continue
            } catch let error as CKError where error.code == .zoneNotFound {
                return []   // 还没有任何人说过话 / 提过案
            }
            for (id, result) in changes.modificationResultsByID {
                // 同分区还有提案（BCProposal）与主动消息（BCAgentMessage）：只收对话记录。
                if case let .success(m) = result, m.record.recordType == Self.recordType { known[id] = m.record }
            }
            for d in changes.deletions { known[d.recordID] = nil }
            changeToken = changes.changeToken; more = changes.moreComing
        }
        return known.values.compactMap(decode).sorted { $0.createdAt < $1.createdAt }
    }

    /// 只有两种更新：Mac 写「已转交」回执、（将来）撤回。都是单写者字段，按改动键保存即可。
    func save(_ message: AgentChatMessage) async throws {
        let id = recordID(message.id)
        let base: CKRecord
        if let cached = known[id]?.copy() as? CKRecord { base = cached } else { base = try await db.record(for: id) }
        try encode(message, into: base)
        let (results, _) = try await db.modifyRecords(saving: [base], deleting: [], savePolicy: .changedKeys, atomically: true)
        switch results[id] {
        case let .success(saved)?: known[id] = saved
        case let .failure(error)?: throw error
        case nil: break
        }
    }

    /// W35：条件写（ifServerRecordUnchanged）——服务器上已有回执就不覆盖；撞上别人同时写 → 重读再判。
    func claim(_ id: UUID, deviceId: String, note: String?, at: Date) async throws -> AgentChatClaim {
        let rid = recordID(id)
        for _ in 0..<3 {
            let fresh = try await db.record(for: rid)
            guard var m = decode(fresh) else { throw URLError(.cannotDecodeContentData) }
            if m.forwardedAt != nil { known[rid] = fresh; return .taken(m) }
            m.forwardedAt = at; m.forwardedByDeviceId = deviceId; m.forwardedNote = note
            try encode(m, into: fresh)
            let (results, _) = try await db.modifyRecords(saving: [fresh], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            switch results[rid] {
            case let .success(saved)?: known[rid] = saved; return .won(m)
            case let .failure(error)? where (error as? CKError)?.code == .serverRecordChanged: continue
            case let .failure(error)?: throw error
            case nil: return .won(m)
            }
        }
        throw URLError(.cannotLoadFromNetwork)   // 连续三次撞上别人的写入：交给下一轮再判（不会两边都回）
    }
}

// MARK: - 通知规则

/// 智能体对话消息要不要弹通知。
/// - 回应型（回复你刚说的话 / 你自己定了时刻的晚间复盘）：是你要的，不计入频率上限、不受「主动通知总开关」与安静时段限制；
///   但「一键静音」始终有效（通知铁则：一键静音始终都在）。
/// - 主动型（智能体自己开口）：完全按 AttentionPolicy（C3）走，与 notify_jason 共用同一份设置与频率额度。
nonisolated enum AgentChatNotifyPolicy {
    static func isSolicited(_ draft: AgentChatReplyDraft) -> Bool { draft.replyTo != nil || draft.kind == .eveningReview }

    static func evaluate(_ draft: AgentChatReplyDraft, settings: AttentionSettings, at now: Date,
                         recentProactive: [Date]) -> AttentionVerdict {
        guard isSolicited(draft) else { return AttentionPolicy.evaluate(settings, at: now, recentDeliveries: recentProactive) }
        if let until = settings.mutedUntil, now < until {
            return .suppress("静音中（到 \(until.formatted(date: .omitted, time: .shortened))）")
        }
        return .allow
    }
}

/// 晚间复盘的措辞自检（只告警、不拦截）：正反馈原则禁止出现的词一旦出现，开发期必须可见。
nonisolated enum AgentChatToneLint {
    static let forbidden = ["失败", "落后", "拖延", "又没", "没做到", "没完成", "完成率", "缺口"]
    static func flags(_ text: String) -> [String] { forbidden.filter { text.contains($0) } }
}

// MARK: - 你的消息在路上走到哪了（失败 / 离线必须可见）

nonisolated enum AgentChatUserStatus: Equatable, Sendable {
    case sending
    case failed(String)
    /// 已存进 iCloud，等 Mac 取走（overdue = 超过 2 分钟还没取走，提示检查 Mac）。
    case waitingForMac(overdue: Bool)
    /// 超过转交时限（6 小时）仍没被取走：Mac 不会再转交，免得智能体回一句过时的话。
    case expired
    /// 已转交智能体（overdue = 超过 10 分钟没回复，提示检查调度器）。
    case withAgent(overdue: Bool)
    case replied

    var label: String {
        switch self {
        case .sending: "发送中…"
        case let .failed(why): "没发出去：\(why)"
        case .waitingForMac(false): "已存到 iCloud，等 Mac 转交给智能体"
        case .waitingForMac(true): "Mac 还没取走：需要 Mac 开着 BetterCalendar 并连接智能体 bridge 文件夹"
        case .expired: "没送到：超过 6 小时 Mac 都没取走，不再转交（可以重新说一次）"
        case .withAgent(false): "智能体已收到，正在想"
        case .withAgent(true): "智能体超过 10 分钟没回复：检查 Mac 上的调度器是否在运行"
        case .replied: "已回复"
        }
    }
    var isProblem: Bool {
        switch self {
        case .failed, .expired, .waitingForMac(true), .withAgent(true): true
        default: false
        }
    }
}

@MainActor protocol AgentChatNotifying {
    func show(_ message: AgentChatMessage) async
    func withdraw(_ ids: [UUID]) async
}

/// 测试 host 用：不碰系统通知中心。
@MainActor final class SilentAgentChatNotifier: AgentChatNotifying {
    func show(_ message: AgentChatMessage) async {}
    func withdraw(_ ids: [UUID]) async {}
}

// MARK: - 协调者

@MainActor @Observable final class AgentChatCenter {
    /// 已存进 iCloud 的对话（按时间升序）。
    private(set) var messages: [AgentChatMessage] = []
    /// 还没存进 iCloud 的你的消息（发送中 / 失败待重试）；本机持久化，重启不丢。
    private(set) var outbox: [AgentChatMessage] = []
    private(set) var outboxErrors: [UUID: String] = [:]
    private(set) var lastError: String?
    private(set) var lastRefresh: Date?
    private(set) var unreadCount = 0

    /// 对话页正在前台显示：新回复不弹通知、直接算已读。
    private(set) var isViewing = false

    static let forwardWindow: TimeInterval = 6 * 3600
    static let macPickupGrace: TimeInterval = 120
    static let replyGrace: TimeInterval = 600
    static let historyLimit = 300

    let deviceId: String
    let deviceLabel: String
    private let transport: any AgentChatTransport
    private let notifier: any AgentChatNotifying
    let ledger: any OperationLedger
    private let defaults: UserDefaults
    private let now: () -> Date
    /// 打扰规则设置与主动通知额度：与 AgentMessageCenter 共用（组装点注入）。
    var attention: () -> AttentionSettings = { AttentionSettings.load() }
    var recentProactiveDeliveries: () -> [Date] = { [] }
    /// W20：你的一句话已存进 iCloud（本机说的）→ 组装点接到当前智能体（内置智能体在本机进程内接手）。
    var onUserMessageStored: ((AgentChatMessage) -> Void)?
    /// W35：每次从 iCloud 拉到对话后（组装点接到当前智能体：Mac 据此接手 iPhone 上说的话）。
    var onRefreshed: (() -> Void)?
    private var shownHere: Set<UUID>
    /// 本机已写过 user_message 事件的消息（回执写 iCloud 失败时也不重复唤醒智能体）。
    private var forwardedHere: Set<UUID>

    private static let outboxKey = "agentChat.outbox.v1"
    /// W31b：没发出去的真实原因也存本机（原来重启后一律显示「上次没发出去」，看不出为什么）。
    private static let outboxErrorsKey = "agentChat.outboxErrors.v1"
    /// 没留下原因时的说法（同一 id 重试，iCloud 侧幂等，不会多出一条）。
    /// W33 自测（P4 不虚报）：原来写「发送途中 App 被关掉了」——但从旧版升级上来的发件箱也没有原因（旧版不存），
    /// 那些其实是发送失败、不是被关掉；只说确定的事：没发出去、原因没记下。
    nonisolated static let interruptedSendReason = "没发出去，当时的原因没记下（可能是发送途中 App 被关掉；重试不会重复）"
    private static let shownKey = "agentChat.shownHere"
    private static let forwardedKey = "agentChat.forwardedHere"
    private static let lastReadKey = "agentChat.lastReadAt"

    init(transport: any AgentChatTransport, notifier: any AgentChatNotifying, ledger: any OperationLedger,
         deviceId: String, deviceLabel: String, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.transport = transport; self.notifier = notifier; self.ledger = ledger
        self.deviceId = deviceId; self.deviceLabel = deviceLabel; self.defaults = defaults; self.now = now
        shownHere = Set((defaults.stringArray(forKey: Self.shownKey) ?? []).compactMap(UUID.init))
        forwardedHere = Set((defaults.stringArray(forKey: Self.forwardedKey) ?? []).compactMap(UUID.init))
        if let data = defaults.data(forKey: Self.outboxKey), let saved = try? JSONDecoder().decode([AgentChatMessage].self, from: data) {
            outbox = saved
            let why = defaults.dictionary(forKey: Self.outboxErrorsKey) as? [String: String] ?? [:]
            for m in saved { outboxErrors[m.id] = why[m.id.uuidString] ?? Self.interruptedSendReason }
        }
    }

    /// 对话页显示用：已存的 + 还没发出去的，按时间排。
    var timeline: [AgentChatMessage] {
        (messages + outbox.filter { o in !messages.contains { $0.id == o.id } }).sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: 你说一句

    /// inReplyToProposal（W10）= 这句话是在回某个提案（从通知 / 面板 / 对话卡片上「回一句」）。
    @discardableResult
    func send(_ raw: String, inReplyToProposal proposalId: UUID? = nil, attachments: [ChatAttachment] = []) async -> AgentChatMessage? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return nil }
        let at = now()
        // 回提案：接着带这张卡片的那条智能体消息说；否则接着最近一条智能体消息说（如复盘后补一句）：6 小时内才算接话。
        let carrier = proposalId.flatMap { id in messages.last { $0.author == .agent && $0.proposalIds.contains(id) } }
        let lastAgent = carrier ?? messages.last { $0.author == .agent && at.timeIntervalSince($0.createdAt) < Self.forwardWindow }
        var m = AgentChatMessage(id: UUID(), createdAt: at, author: .user, deviceId: deviceId, deviceLabel: deviceLabel,
                                 text: String(text.prefix(2000)), kind: .chat, replyTo: lastAgent?.id)
        m.inReplyToProposal = proposalId
        if !attachments.isEmpty { m.attachments = Array(attachments.prefix(ChatAttachmentStore.maxPerMessage)) }
        outbox.append(m); persistOutbox()
        return await post(m)
    }

    /// 失败的消息重发（同一个 id，iCloud 侧幂等）。
    @discardableResult
    func retry(_ id: UUID) async -> AgentChatMessage? {
        guard let m = outbox.first(where: { $0.id == id }) else { return nil }
        return await post(m)
    }

    /// 放弃一条没发出去的消息（只删本机草稿，从没进过 iCloud）。
    func discard(_ id: UUID) {
        outbox.removeAll { $0.id == id }; outboxErrors[id] = nil; persistOutbox()
    }

    /// W31 自测：iCloud 没登录 / 网络卡住时 CloudKit 写入可能永远不回——气泡一直「发送中…」（模拟器实测 9 分钟以上）。
    /// 超过这么久就当「没发出去」显示原因 + 重试（同一 id，iCloud 侧幂等；万一迟到的写入其实成功了，下次刷新会把它从发件箱收走）。
    var sendTimeout: TimeInterval = 30

    private func post(_ m: AgentChatMessage) async -> AgentChatMessage? {
        outboxErrors[m.id] = nil
        do {
            let transport = self.transport
            try await CloudDeadline.race(seconds: sendTimeout) { try await transport.post(m) }
            outbox.removeAll { $0.id == m.id }; persistOutbox()
            record(.user, "你", "chat.sent", m, "在 \(deviceLabel) 说：\(m.text.prefix(40))")
            await refresh()
            onUserMessageStored?(m)   // W20：内置智能体在本机接手（Claude Code 走 Mac 桥接转交，不用这个口）
            return m
        } catch {
            outboxErrors[m.id] = error.localizedDescription
            persistOutbox()
            fail("消息没发出去（已留在本机，可重试）", error)
            return nil
        }
    }

    // MARK: 同步（推送唤醒 / 回前台 / 轮询 / Mac 桥接每轮）

    func refresh() async {
        do { messages = Array(try await transport.fetchRecent().suffix(Self.historyLimit)) }
        catch { fail("读取对话失败", error); return }
        DevLog.shared.resolve(source: "智能体对话")   // W16：拉取成功 = 短暂失败自动消除
        lastRefresh = now()
        // 别的设备已经发出去的同 id 消息不再留在本机发件箱。
        let stored = Set(messages.map(\.id))
        if outbox.contains(where: { stored.contains($0.id) }) { outbox.removeAll { stored.contains($0.id) }; persistOutbox() }
        let cutoff = now().addingTimeInterval(-Self.forwardWindow)
        for m in messages where m.author == .agent && m.delivery == .delivered && m.createdAt > cutoff && !shownHere.contains(m.id) {
            shownHere.insert(m.id)
            if isViewing { continue }   // 正看着对话页：不弹
            await notifier.show(m)
            record(.system, "BetterCalendar", "chat.notified", m, "已在本机弹出")
        }
        defaults.set(Array(shownHere.map(\.uuidString).suffix(300)), forKey: Self.shownKey)
        if isViewing { await markAllRead() } else { recomputeUnread() }
        onRefreshed?()
    }

    /// 对话页出现 / 消失（含回后台）时调用。
    func setViewing(_ on: Bool) async {
        isViewing = on
        if on { await markAllRead() }
    }

    func markAllRead() async {
        let agentIds = messages.filter { $0.author == .agent }.map(\.id)
        if let last = messages.last(where: { $0.author == .agent })?.createdAt {
            defaults.set(max(last.timeIntervalSince1970, defaults.double(forKey: Self.lastReadKey)), forKey: Self.lastReadKey)
        }
        recomputeUnread()
        await notifier.withdraw(Array(agentIds.suffix(50)))
    }

    private func recomputeUnread() {
        let lastRead = defaults.double(forKey: Self.lastReadKey)
        unreadCount = messages.filter { $0.author == .agent && $0.createdAt.timeIntervalSince1970 > lastRead }.count
    }

    // MARK: Mac 桥接用

    /// 等着转交给智能体的你的消息：还没有回执、本机也没转交过、且在转交时限内。
    func pendingForwards() -> [AgentChatMessage] {
        let cutoff = now().addingTimeInterval(-Self.forwardWindow)
        return messages.filter { $0.author == .user && $0.forwardedAt == nil && !forwardedHere.contains($0.id) && $0.createdAt > cutoff }
    }

    /// W35：内置智能体接手前先认领（先到先得）。true = 本机接手；false = 别的设备已接手；nil = 没写成（原因可见，下一轮再试）。
    func claimForAgent(_ id: UUID, note: String? = nil) async -> Bool? {
        do {
            switch try await transport.claim(id, deviceId: deviceId, note: note, at: now()) {
            case let .won(m):
                replaceLocal(m)
                forwardedHere.insert(id)
                defaults.set(Array(forwardedHere.map(\.uuidString).suffix(300)), forKey: Self.forwardedKey)
                record(.system, "BetterCalendar（\(deviceLabel)）", "chat.claimed", m, note ?? "本机智能体接手")
                return true
            case let .taken(m):
                replaceLocal(m)
                return m.forwardedByDeviceId == deviceId
            }
        } catch {
            fail("认领这句话失败（下一轮再试）", error)
            return nil
        }
    }

    private func replaceLocal(_ m: AgentChatMessage) {
        if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i] = m }
    }

    /// W35：你那句话下面的一行说明——不是在说话的那台设备上接手、或说话的设备自己兜底时写明。
    func handlerNote(_ m: AgentChatMessage) -> String? {
        let latest = messages.first { $0.id == m.id } ?? m
        return latest.forwardedNote
    }

    /// 已写好 user_message 事件：先本机记下（防重复唤醒），再把回执写回 iCloud 让各端显示「智能体已收到」。
    func markForwarded(_ id: UUID) async {
        forwardedHere.insert(id)
        defaults.set(Array(forwardedHere.map(\.uuidString).suffix(300)), forKey: Self.forwardedKey)
        guard var m = messages.first(where: { $0.id == id }) else { return }
        if m.forwardedAt != nil, m.forwardedByDeviceId == deviceId { return }   // W35：认领时已写过回执
        m.forwardedAt = now(); m.forwardedByDeviceId = deviceId
        do {
            try await transport.save(m)
            if let i = messages.firstIndex(where: { $0.id == id }) { messages[i] = m }
            record(.system, "BetterCalendar（\(deviceLabel)）", "chat.forwarded", m, "已转交智能体")
        } catch { fail("写「已转交」回执失败（智能体已收到，只是别的设备暂时看不到）", error) }
    }

    /// 智能体回复（Mac 桥接导入）：先按通知规则定一次弹不弹，再存 iCloud 同步各端。幂等（同 id 只收一次）。
    @discardableResult
    func receiveAgent(_ draft: AgentChatReplyDraft) async -> AgentChatMessage? {
        await refresh()
        if let existing = messages.first(where: { $0.id == draft.id }) { return existing }
        var at = now()
        // 两台设备时钟有差：回复永远排在它回应的那句话之后。
        if let asked = draft.replyTo.flatMap({ id in messages.first { $0.id == id } }), asked.createdAt >= at {
            at = asked.createdAt.addingTimeInterval(1)
        }
        let proactive = recentProactiveDeliveries() + messages
            .filter { $0.author == .agent && $0.delivery == .delivered && $0.replyTo == nil && $0.kind == .chat }.map(\.createdAt)
        var m = AgentChatMessage(id: draft.id, createdAt: at, author: .agent, deviceId: deviceId, deviceLabel: deviceLabel,
                                 text: draft.text, kind: draft.kind, replyTo: draft.replyTo, proposalIds: draft.proposalIds,
                                 parentRef: draft.parentRef, delivery: .delivered)
        m.sources = draft.sources.isEmpty ? nil : draft.sources
        if case let .suppress(why) = AgentChatNotifyPolicy.evaluate(draft, settings: attention(), at: at, recentProactive: proactive) {
            m.delivery = .suppressed; m.suppressReason = why
        }
        if draft.kind == .eveningReview {
            let hits = AgentChatToneLint.flags(draft.text)
            if !hits.isEmpty { DevLog.shared.warn("智能体对话", "晚间复盘出现了正反馈原则禁用的词：\(hits.joined(separator: "、"))") }
        }
        do {
            try await transport.post(m)
            record(.agent, draft.originLabel ?? "BetterCalendar 智能体", draft.kind == .eveningReview ? "chat.review" : "chat.reply", m,
                   (m.delivery == .delivered ? "" : "（不弹通知：\(m.suppressReason ?? "")）") + m.text.prefix(40))
            await refresh()
            return messages.first { $0.id == m.id } ?? m
        } catch {
            fail("保存智能体回复失败", error); return nil
        }
    }

    // MARK: 给界面

    func status(of given: AgentChatMessage) -> AgentChatUserStatus {
        let m = messages.first { $0.id == given.id } ?? given   // 以最新同步到的版本为准（回执可能刚到）
        if let why = outboxErrors[m.id] { return .failed(why) }
        if outbox.contains(where: { $0.id == m.id }) { return .sending }
        if messages.contains(where: { $0.author == .agent && $0.replyTo == m.id }) { return .replied }
        let at = now()
        if let f = m.forwardedAt {
            // 智能体可能一次回复了连续几句：之后有任何智能体消息都算已回应。
            if messages.contains(where: { $0.author == .agent && $0.createdAt > f }) { return .replied }
            return .withAgent(overdue: at.timeIntervalSince(f) > Self.replyGrace)
        }
        let age = at.timeIntervalSince(m.createdAt)
        if age > Self.forwardWindow { return .expired }
        return .waitingForMac(overdue: age > Self.macPickupGrace)
    }

    func clearError() { lastError = nil }

    /// W20：当前接通的智能体（组装点注入）。只影响「你的消息走到哪」的说法：内置智能体在说话的那台设备上接手，不经 Mac。
    var activeAgent: () -> AgentKind = { .claudeCode }

    /// 给界面的状态说法（P4 不让你猜：内置智能体时不再提「等 Mac 转交」）。
    func label(for status: AgentChatUserStatus) -> String {
        guard activeAgent() == .builtin else { return status.label }
        switch status {
        case .waitingForMac(false): return "已存到 iCloud，智能体马上接手"
        case .waitingForMac(true): return "还没有设备接手：打开说这句话的那台设备上的 BetterCalendar，或开着 Mac（看 设置 → 智能体 的状态）"
        case .withAgent(true): return "内置智能体超过 10 分钟没回复：看 设置 → 智能体 的状态"
        case .expired: return "没送到：超过 6 小时都没被接手，不再处理（可以重新说一次）"
        default: return status.label
        }
    }

    private func persistOutbox() {
        if outbox.isEmpty { defaults.removeObject(forKey: Self.outboxKey) }
        else if let data = try? JSONEncoder().encode(outbox) { defaults.set(data, forKey: Self.outboxKey) }
        // 原因跟着发件箱一起存（只留还在发件箱里的）
        let ids = Set(outbox.map(\.id))
        let why = Dictionary(uniqueKeysWithValues: outboxErrors.filter { ids.contains($0.key) }.map { ($0.key.uuidString, $0.value) })
        if why.isEmpty { defaults.removeObject(forKey: Self.outboxErrorsKey) } else { defaults.set(why, forKey: Self.outboxErrorsKey) }
    }

    private func record(_ actor: ProposalOrigin, _ label: String, _ event: String, _ m: AgentChatMessage, _ detail: String) {
        ledger.append(OperationRecord(at: now(), actor: actor, actorLabel: label, deviceId: deviceId, event: event,
                                      proposalId: m.id, parentId: m.replyTo, parentRef: m.parentRef, detail: detail))
    }

    private func fail(_ what: String, _ error: Error) {
        lastError = "\(what)：\(error.localizedDescription)"
        DevLog.shared.error("智能体对话", lastError!)
    }
}
