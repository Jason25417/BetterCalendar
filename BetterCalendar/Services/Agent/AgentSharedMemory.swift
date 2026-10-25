//
//  AgentSharedMemory.swift
//  BetterCalendar
//
//  W20（Jason 2026-10-19 改定）：「BetterCalendar 智能体」这个角色的共享记忆——不属于任何一种实现。
//  哪个实现接通，就读写这同一份：你的偏好、正在跟进的事、最近被拒的提议、备忘。
//    · 内置智能体：每轮开工时读（写进系统提示），用工具 update_shared_memory 整份改写。
//    · Claude Code：App 每轮桥接同步把它写成 bridge/shared-memory.md（只读快照）；它写 bridge/shared-memory.update.json
//      整份改写，App 导入（它自己的 memory/notes.md 仍可当私人草稿，长期该记住的进这里）。
//  存储：随 iCloud 设置同步的 UserDefaults 字符串（键在 SettingsSync 白名单；不建新的 CloudKit 记录类型）。
//  设上限（技术稳定上限，不是产品规则）：超出就拒绝写入并写明原因，绝不悄悄截断。
//  0.75（10-24 21:30 Mac 晚间复盘把 iPhone 白天攒到 2690 字的记忆整份改成 707 字）：整份改写加两道闸——
//    ① 读过之后被另一台改过 → 拒收、给最新全文，在它基础上再改；② 一次砍掉四成以上 → 要明确说「就是要精简」（confirmShrink）。
//    每次改写前的旧版本在本机留最近 10 份（不同步），丢了能找回。
//

import Foundation
import Observation

nonisolated struct AgentSharedMemory: Codable, Equatable, Sendable {
    var text: String
    var updatedAt: Date
    /// 哪个实现写的（AgentKind.shortLabel）+ 哪台设备。
    var updatedBy: String
}

nonisolated enum AgentSharedMemoryError: Error, LocalizedError, Equatable {
    case tooLong(Int)
    case empty
    case changedSinceRead(by: String, text: String)
    case wouldShrink(from: Int, to: Int)
    var errorDescription: String? {
        switch self {
        case let .changedSinceRead(by, text): "共享记忆在你读过之后被「\(by)」改过，这次没写入。最新全文如下，请在它基础上整份改写（别丢掉别人新加的）：\n\(text)"
        case let .wouldShrink(from, to): "这次改写会把共享记忆从 \(from) 字砍到 \(to) 字，没写入：整份改写会删掉你没写进来的所有内容。请把现有内容保留下来再加新的；确实是有意精简，就带上 confirmShrink: true 再写一次"
        case let .tooLong(n): "共享记忆不能超过 \(AgentSharedMemoryStore.maxCharacters) 字（这次 \(n) 字）：请精简——合并重复、删掉已经过时的跟进，再整份写一次"
        case .empty: "共享记忆不能写成空的；要清掉某条就整份改写时去掉那条"
        }
    }
}

@MainActor @Observable final class AgentSharedMemoryStore {
    static let key = "agent.sharedMemory.v1"
    /// 技术稳定上限（iCloud 键值存储单键 1MB、整库 1MB；也让每轮系统提示保持小）。不是产品规则。
    static let maxCharacters = 6000
    /// 0.75：现有记忆至少这么长时，一次改写不能短于原来的 shrinkRatio（除非明确确认精简）。
    static let shrinkGuardFloor = 800
    static let shrinkRatio = 0.6
    static let historyKey = "agent.sharedMemory.history.v1"   // 不进 SettingsSync：只在本机，找回用
    static let historyLimit = 10

    private(set) var memory: AgentSharedMemory?
    private(set) var lastError: String?
    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
        reload()
    }

    /// 读本地（另一台设备写了、SettingsSync 落到本地后也调这里）。读坏了不覆盖原数据，可见。
    func reload() {
        guard let raw = defaults.string(forKey: Self.key) else { memory = nil; return }
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            memory = try decoder.decode(AgentSharedMemory.self, from: Data(raw.utf8))
            lastError = nil
        } catch {
            memory = nil
            lastError = "共享记忆读不出来（原数据未改）：\(error.localizedDescription)"
            DevLog.shared.error("智能体共享记忆", lastError!)
        }
    }

    /// 整份改写。返回写入后的记忆；超上限 / 空 / 读后被改过 / 一次砍太多 → 抛出（不截断、不覆盖）。
    /// basedOn = 写的人读到的那份的更新时间（nil = 不核对，如 Claude Code 桥接只拿到快照）。
    @discardableResult
    func replace(_ raw: String, by writer: String, basedOn: Date? = nil, confirmShrink: Bool = false) throws -> AgentSharedMemory {
        let text = Self.strippingSnapshotHeader(raw)
        guard !text.isEmpty else { throw AgentSharedMemoryError.empty }
        guard text.count <= Self.maxCharacters else { throw AgentSharedMemoryError.tooLong(text.count) }
        reload()   // 以本机此刻最新的为准（另一台的改写可能刚经 iCloud 落地）
        let current = memory
        if let basedOn, let current, current.updatedAt.timeIntervalSince(basedOn) > 1 {   // 存储只到秒
            throw AgentSharedMemoryError.changedSinceRead(by: current.updatedBy, text: current.text)
        }
        if !confirmShrink, let current, current.text.count >= Self.shrinkGuardFloor,
           Double(text.count) < Double(current.text.count) * Self.shrinkRatio {
            throw AgentSharedMemoryError.wouldShrink(from: current.text.count, to: text.count)
        }
        let m = AgentSharedMemory(text: text, updatedAt: now(), updatedBy: writer)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let current, let old = try? encoder.encode(current) {
            let kept = (defaults.stringArray(forKey: Self.historyKey) ?? []) + [String(decoding: old, as: UTF8.self)]
            defaults.set(Array(kept.suffix(Self.historyLimit)), forKey: Self.historyKey)
        }
        defaults.set(String(decoding: try encoder.encode(m), as: UTF8.self), forKey: Self.key)   // String = plist 类型，可进 iCloud KV
        memory = m
        lastError = nil
        DevLog.shared.info("智能体共享记忆", "已更新（\(text.count) 字" + (current.map { "，原 \($0.text.count) 字" } ?? "") + "，\(writer)）")
        return m
    }

    /// 智能体常把给它看的快照标题（「# BetterCalendar 智能体共享记忆」+「> 最后更新…」）原样抄回正文（10-25 实见）→ 去掉，免得一层层套娃。
    nonisolated static func strippingSnapshotHeader(_ raw: String) -> String {
        var lines = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "# BetterCalendar 智能体共享记忆" { lines.removeFirst() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty || first.hasPrefix("> 最后更新：") { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 本机留的旧版本（新的在后）。
    func history() -> [AgentSharedMemory] {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (defaults.stringArray(forKey: Self.historyKey) ?? []).compactMap { try? d.decode(AgentSharedMemory.self, from: Data($0.utf8)) }
    }

    /// 只由你在设置里点「清空」触发。
    func clear() {
        defaults.removeObject(forKey: Self.key)
        memory = nil
    }

    /// 给智能体看的 Markdown（内置智能体的系统提示、Claude Code 的 bridge/shared-memory.md 同一份）。
    nonisolated static func markdown(_ m: AgentSharedMemory?) -> String {
        guard let m else {
            return "# BetterCalendar 智能体共享记忆\n\n（还是空的。值得长期记住的——Jason 的偏好、正在跟进的事、最近被拒的提议——整份写进来。）\n"
        }
        let iso = ISO8601DateFormatter()
        return "# BetterCalendar 智能体共享记忆\n\n> 最后更新：\(iso.string(from: m.updatedAt))（\(m.updatedBy)）· 上限 \(maxCharacters) 字 · 改写 = 整份替换\n\n\(m.text)\n"
    }
}

// MARK: - 桥接（Claude Code 一侧）

extension AgentBridgeIO {
    static let sharedMemoryPath = "shared-memory.md"
    static let sharedMemoryUpdatePath = "shared-memory.update.json"

    /// App → Claude Code：只读快照（内容变化才重写）。
    func writeSharedMemory(_ m: AgentSharedMemory?) throws {
        let data = Data(AgentSharedMemoryStore.markdown(m).utf8)
        if (try? Data(contentsOf: root.appendingPathComponent(Self.sharedMemoryPath))) != data { try writeAtomic(data, to: Self.sharedMemoryPath) }
    }

    /// Claude Code → App：`shared-memory.update.json` = `{schemaVersion:1, text}`（整份改写）。没有文件 = nil。
    /// 坏文件 → 抛出（调用方移到 shared-memory.rejected.json 并写原因）。
    func pendingSharedMemoryUpdate() throws -> String? {
        let url = root.appendingPathComponent(Self.sharedMemoryUpdatePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let o = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], o["schemaVersion"] as? Int == 1 else {
            throw AgentBridgeError.invalid("不是 v1 共享记忆更新文件（{schemaVersion:1, text}）")
        }
        let unknown = Set(o.keys).subtracting(["schemaVersion", "text", "confirmShrink"])
        guard unknown.isEmpty else { throw AgentBridgeError.invalid("不认识的字段：\(unknown.sorted().joined(separator: ", "))") }
        guard let text = o["text"] as? String else { throw AgentBridgeError.invalid("缺少 text（整份共享记忆）") }
        return text
    }

    /// 0.75：更新文件里带 `confirmShrink: true` = 有意精简（一次砍掉四成以上也照写）。
    func pendingSharedMemoryConfirmShrink() -> Bool {
        let url = root.appendingPathComponent(Self.sharedMemoryUpdatePath)
        guard let data = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return o["confirmShrink"] as? Bool == true
    }

    func finishSharedMemoryUpdate(rejected reason: String?) throws {
        let url = root.appendingPathComponent(Self.sharedMemoryUpdatePath)
        if let reason {
            let dest = root.appendingPathComponent("shared-memory.rejected.json")
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: url, to: dest)
            try writeAtomic(Data(reason.utf8), to: "shared-memory.rejected.reason.txt")
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }
}
