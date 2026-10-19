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
    var errorDescription: String? {
        switch self {
        case let .tooLong(n): "共享记忆不能超过 \(AgentSharedMemoryStore.maxCharacters) 字（这次 \(n) 字）：请精简——合并重复、删掉已经过时的跟进，再整份写一次"
        case .empty: "共享记忆不能写成空的；要清掉某条就整份改写时去掉那条"
        }
    }
}

@MainActor @Observable final class AgentSharedMemoryStore {
    static let key = "agent.sharedMemory.v1"
    /// 技术稳定上限（iCloud 键值存储单键 1MB、整库 1MB；也让每轮系统提示保持小）。不是产品规则。
    static let maxCharacters = 6000

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

    /// 整份改写。返回写入后的记忆；超上限 / 空 → 抛出（不截断）。
    @discardableResult
    func replace(_ raw: String, by writer: String) throws -> AgentSharedMemory {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentSharedMemoryError.empty }
        guard text.count <= Self.maxCharacters else { throw AgentSharedMemoryError.tooLong(text.count) }
        let m = AgentSharedMemory(text: text, updatedAt: now(), updatedBy: writer)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        defaults.set(String(decoding: try encoder.encode(m), as: UTF8.self), forKey: Self.key)   // String = plist 类型，可进 iCloud KV
        memory = m
        lastError = nil
        DevLog.shared.info("智能体共享记忆", "已更新（\(text.count) 字，\(writer)）")
        return m
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
        let unknown = Set(o.keys).subtracting(["schemaVersion", "text"])
        guard unknown.isEmpty else { throw AgentBridgeError.invalid("不认识的字段：\(unknown.sorted().joined(separator: ", "))") }
        guard let text = o["text"] as? String else { throw AgentBridgeError.invalid("缺少 text（整份共享记忆）") }
        return text
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
