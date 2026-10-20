//
//  TextDraftStore.swift
//  BetterCalendar
//
//  W29（Jason 要求）：你在输入框里打了一半的字，App 被杀 / 重启后还在。
//  覆盖所有「跟智能体说一句」与新建事项的自由文本框（清单见 TextDraftKey）。
//  - 打字时存（视图里防抖 0.4 秒，离开页面立刻存）；出现时还原；**只在发送 / 提交成功后清空**。
//    你自己点「取消 / ✕」把字清掉 = 你决定不要了，也一并清掉。发送失败时字留在原处（失败可见）。
//  - 存储：**只在本机**（UserDefaults 一个 [String: [String: Any]] 字典，纯 plist 类型）。草稿不是设置，不进 iCloud 设置同步；
//    跨设备接力草稿是以后可以加的（W29 报告里请 Jason 拍板）。
//  - 30 天没动的草稿自动丢掉（对应的提案早已作废、页面早已不在，防止字典无限长）。
//  - 测试宿主里 UserDefaults.standard 已被 TestHostIsolation 换成一次性 suite；单测各自注入自己的 suite。
//  - W30（原则 11：打了一半的字是「状态」，属于人不属于设备）：跨设备接力（DraftHandoff，iCloud KV，开关 drafts.handoff.enabled）。
//    规则：只在本机输入框**是空的**时才把别处的草稿填进来（绝不覆盖你眼前的字）；两边都有 → 最新的赢；
//    在任一台发送成功 / 清空 → 写一个「已清空」记号，其他设备下次打开那个框时也清掉（不再冒出已发过的字）；
//    每格最多 4000 字（更长的只留在本机）；只接力 TextDraftKey 白名单里的框（API Key 之类的输入框不是草稿，永远不进来）。
//

import Foundation
import SwiftUI

/// 一个输入框的草稿键（稳定字符串；改名 = 旧草稿找不到，所以只增不改）。
nonisolated enum TextDraftKey {
    static let agentChat = "agentChat"                 // 智能体页「跟智能体说一句」
    static let todaySay = "today.say"                  // 今天页底部「跟智能体说一句」
    static let todayAddRow = "today.addRow"            // 今天页列表尾行「加一项」
    static let longtermSay = "longterm.say"            // 长期页「说一句」
    static let longtermAddManual = "longterm.addManual" // 长期页「手动加一件」
    static let longtermAddTodo = "longterm.addTodo"    // 长期页「记一件想做的小事」
    static let executionAdHoc = "execution.adHoc"      // 执行陪伴「+ 新事项」标题（再点开「新事项」时填回）
    static let bridgeTaskTitle = "execution.bridgeTask"   // 实验「正在做什么」开始事项
    static let feedback = "feedback"                   // 设置 → 反馈正文
    static func proposalReply(_ id: UUID) -> String { "proposal.reply." + id.uuidString }   // 提案「回一句」（每份提案一格）
    static func checkpointAdd(_ taskId: UUID) -> String { "longterm.checkpoint." + taskId.uuidString }   // 长期详情「加一个阶段」

    /// W30：可以跨设备接力的框（白名单：只增不改；设置里的 API Key 等字段不是草稿、永远不在这里）。
    static let handoffKeys: Set<String> = [agentChat, todaySay, todayAddRow, longtermSay, longtermAddManual, longtermAddTodo,
                                           executionAdHoc, bridgeTaskTitle, feedback]
    static func handoffAllowed(_ key: String) -> Bool {
        guard !key.lowercased().contains("apikey"), !key.lowercased().contains("secret") else { return false }
        return handoffKeys.contains(key) || key.hasPrefix("proposal.reply.") || key.hasPrefix("longterm.checkpoint.")
    }
}

/// W30：草稿跨设备接力（iCloud KV，每个框一个键 textDraft.<框>，不新建 CloudKit 记录）。
nonisolated final class DraftHandoff: @unchecked Sendable {
    static let enabledKey = "drafts.handoff.enabled"
    static let prefix = "textDraft."
    /// 每格上限（iCloud KV 总共只有 1MB；更长的草稿只留在本机）。
    static let maxChars = 4000
    /// 最多同时接力多少格（提案「回一句」每份一格，防止越积越多）。
    static let maxKeys = 40

    nonisolated struct Entry: Codable, Equatable, Sendable {
        /// 空 = 「已清空」记号（在某台发送成功 / 清掉了）。
        var t: String
        var at: Double
        var from: String
    }

    private let kv: any SharedKVStoring
    private let deviceLabel: String
    let isEnabled: @Sendable () -> Bool

    init(kv: any SharedKVStoring, deviceLabel: String = ActivityDeviceKind.current.label,
         isEnabled: @escaping @Sendable () -> Bool = { ExperimentDefaults.newFeature(DraftHandoff.enabledKey) }) {
        self.kv = kv; self.deviceLabel = deviceLabel; self.isEnabled = isEnabled
    }

    func remote(_ key: String) -> Entry? {
        guard let data = kv.data(forKey: Self.prefix + key) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    /// 本机这格变了：发出去（空 = 已清空记号）。太长的不接力（并撤掉云上的旧版本，免得别处拿到过时的半截）。
    func publish(_ key: String, text: String, at: Double) {
        guard isEnabled(), TextDraftKey.handoffAllowed(key) else { return }
        guard text.count <= Self.maxChars else { kv.set(nil, forKey: Self.prefix + key); return }
        guard let data = try? JSONEncoder().encode(Entry(t: text, at: at, from: deviceLabel)) else { return }
        kv.set(data, forKey: Self.prefix + key)
        prune(now: at)
    }

    private func prune(now: Double) {
        let keys = kv.keys(withPrefix: Self.prefix)
        let dated = keys.map { k in (k, kv.data(forKey: k).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }) }
        for (k, e) in dated where e == nil || now - (e?.at ?? 0) > TextDraftStore.maxAge { kv.set(nil, forKey: k) }
        let live = dated.compactMap { k, e in e.flatMap { now - $0.at <= TextDraftStore.maxAge ? (k, $0.at) : nil } }
        guard live.count > Self.maxKeys else { return }
        for (k, _) in live.sorted(by: { $0.1 < $1.1 }).prefix(live.count - Self.maxKeys) { kv.set(nil, forKey: k) }
    }
}

nonisolated final class TextDraftStore: @unchecked Sendable {
    static let defaultsKey = "textDrafts.v1"
    static let maxAge: TimeInterval = 30 * 86_400
    static let maxChars = 20_000
    /// 视图里打字后多久落盘（防抖；离开页面 / 回后台立刻存）。
    static let debounce: Duration = .milliseconds(400)

    static let shared = TextDraftStore(defaults: .standard,
                                       handoff: TestHost.isActive ? nil : DraftHandoff(kv: ICloudSharedKV.shared))

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let handoff: DraftHandoff?
    private let lock = NSLock()

    init(defaults: UserDefaults, now: @escaping @Sendable () -> Date = { Date() }, handoff: DraftHandoff? = nil) {
        self.defaults = defaults; self.now = now; self.handoff = handoff
    }

    /// 读一格草稿（没有 / 过期 → nil）。W30：别的设备上更新的草稿（或「已清空」记号）在这里接过来——
    /// 调用方只在框是空的时候读（PersistedDraftModifier / 再次点开「新事项」），所以不会覆盖你眼前的字。
    func load(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var rows = all()
        let localAt = rows[key]?["at"] as? Double
        if let handoff, handoff.isEnabled(), TextDraftKey.handoffAllowed(key), let r = handoff.remote(key),
           r.at > (localAt ?? -.infinity), now().timeIntervalSince1970 - r.at <= Self.maxAge {
            if r.t.isEmpty {   // 别处发送 / 清空得更晚 → 本机这份是过时的
                if rows.removeValue(forKey: key) != nil { write(rows) }
                return nil
            }
            rows[key] = ["t": r.t, "at": r.at]   // 接过来（保留它的时刻：同一份不会来回接）
            write(rows)
            return r.t
        }
        guard let row = rows[key], let text = row["t"] as? String, !text.isEmpty else { return nil }
        if let at = row["at"] as? Double, now().timeIntervalSince1970 - at > Self.maxAge { return nil }
        return text
    }

    func has(_ key: String) -> Bool { load(key) != nil }

    /// 存一格；空白 = 清掉。内容没变就不写（打字防抖之外再省一次写）。
    func save(_ text: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        var rows = all()
        let at = now().timeIntervalSince1970
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard rows.removeValue(forKey: key) != nil else {
                // 本机没存过（比如接过来的字还没落盘就发出去了），但云上还有别处的草稿 → 也要清掉，免得别处再冒出来
                if let handoff, handoff.remote(key).map({ !$0.t.isEmpty }) ?? false { handoff.publish(key, text: "", at: at) }
                return
            }
            write(rows)
            handoff?.publish(key, text: "", at: at)
        } else {
            let t = String(text.prefix(Self.maxChars))
            if (rows[key]?["t"] as? String) == t { return }
            rows[key] = ["t": t, "at": at]
            write(rows)
            handoff?.publish(key, text: t, at: at)
        }
    }

    func clear(_ key: String) { save("", for: key) }

    /// 现存的全部键（测试 / 诊断用）。
    func keys() -> [String] { lock.lock(); defer { lock.unlock() }; return all().keys.sorted() }

    // MARK: 私有

    private func all() -> [String: [String: Any]] {
        (defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String: Any]]) ?? [:]
    }

    private func write(_ rows: [String: [String: Any]]) {
        let cutoff = now().timeIntervalSince1970 - Self.maxAge
        let kept = rows.filter { ($0.value["at"] as? Double ?? 0) >= cutoff }
        if kept.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) } else { defaults.set(kept, forKey: Self.defaultsKey) }
    }
}

/// 输入框草稿：出现时还原（框里本来是空的才还原）、打字防抖存、离开页面 / 回后台立刻存。
/// 清空靠调用方：发送 / 提交成功后把绑定的字设成 ""（并可直接 store.clear 立刻生效）。
struct PersistedDraftModifier: ViewModifier {
    @Binding var text: String
    /// nil = 这个输入框不存草稿（复用组件时按需开）。
    let key: String?
    var store: TextDraftStore = .shared
    @State private var restored = false
    /// 这个视图上次读到 / 存下的字：没改过就不写（同一输入框开在两个窗口里时，没动过的那个不会把别处已发出的草稿写回来）。
    @State private var lastSynced: String?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                if let key, text.isEmpty, let saved = store.load(key) { text = saved }
                lastSynced = text
                restored = true
            }
            .task(id: text) {
                guard restored else { return }
                try? await Task.sleep(for: TextDraftStore.debounce)
                guard !Task.isCancelled else { return }
                flush()
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { flush() } }
            .onDisappear { flush() }
    }

    private func flush() {
        guard let key, restored, text != lastSynced else { return }
        store.save(text, for: key)
        lastSynced = text
    }
}

extension View {
    /// W29：这个输入框的字在 App 重启后还在（见 TextDraftStore）。
    func persistedDraft(_ text: Binding<String>, key: String?, store: TextDraftStore = .shared) -> some View {
        modifier(PersistedDraftModifier(text: text, key: key, store: store))
    }
}
