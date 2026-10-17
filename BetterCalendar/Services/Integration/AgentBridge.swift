//
//  AgentBridge.swift
//  BetterCalendar
//
//  SPEC §19 P2：App ⇄ BetterCalendar 智能体（Claude Code 专用会话）的桥接目录（协议见智能体工作区 bridge/README.md）。
//  App 在沙盒里，靠用户选一次目录（安全书签）获得读写权：
//    - 写 context.json（今天的安排 + 正在做的事），供智能体 read_context；
//    - 导入 proposals/*.json → 交给 ProposalCenter 走多端审批（来源=智能体），导入后移入 proposals/imported/；
//    - 回写 results/<id>.json（提案最新状态），供智能体 read_proposals。
//  不认识的改动种类一律拒绝导入（移入 proposals/rejected/）并记错误，绝不猜测。
//

import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

nonisolated enum AgentBridgeError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(s) = self { return s }; return nil }
}

/// 桥接目录的文件读写与校验（与书签/计时解耦，便于用临时目录测试）。
nonisolated struct AgentBridgeIO: Sendable {
    let root: URL
    private var fm: FileManager { .default }

    func prepare() throws {
        for sub in ["events", "proposals/imported", "proposals/rejected", "results"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    func writeAtomic(_ data: Data, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try data.write(to: url, options: .atomic)
    }

    func writeContext(_ object: [String: Any]) throws {
        try writeAtomic(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), to: "context.json")
    }

    func pendingProposalFiles() throws -> [URL] {
        try fm.contentsOfDirectory(at: root.appendingPathComponent("proposals"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func move(_ file: URL, to sub: String, note: String? = nil) throws {
        let dest = root.appendingPathComponent("proposals/\(sub)/\(file.lastPathComponent)")
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: file, to: dest)
        if let note { try writeAtomic(Data(note.utf8), to: "proposals/\(sub)/\(file.deletingPathExtension().lastPathComponent).reason.txt") }
    }

    /// 只在内容变化时重写，避免无谓的文件抖动。
    func writeResult(_ p: Proposal, at now: Date) throws {
        let iso = ISO8601DateFormatter()
        let object: [String: Any] = ["id": p.id.uuidString, "title": p.title, "state": p.effectiveState(at: now).rawValue,
                                     "decidedByDeviceId": p.decidedByDeviceId ?? NSNull(), "resultNote": p.resultNote ?? NSNull(),
                                     "updatedAt": iso.string(from: p.appliedAt ?? p.decidedAt ?? p.createdAt)]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let relative = "results/\(p.id.uuidString).json"
        if (try? Data(contentsOf: root.appendingPathComponent(relative))) != data { try writeAtomic(data, to: relative) }
    }

    /// 智能体提案文件 → 草稿。严格校验；当前只接受测试改动（experimentNoop）。
    static func draft(from data: Data) throws -> ProposalDraft {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["schemaVersion"] as? Int == 1 else { throw AgentBridgeError.invalid("不是 v1 提案文件") }
        guard let raw = o["id"] as? String, let id = UUID(uuidString: raw) else { throw AgentBridgeError.invalid("提案 id 缺失或不是 UUID") }
        guard let title = (o["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title.count <= 80
        else { throw AgentBridgeError.invalid("标题缺失或过长") }
        guard let reason = (o["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty
        else { throw AgentBridgeError.invalid("缺少理由（每个改动都必须讲得出依据）") }
        guard let rawChanges = o["changes"] as? [[String: Any]], rawChanges.count <= 10 else { throw AgentBridgeError.invalid("changes 格式错误") }
        let changes = try rawChanges.map { c -> ProposalChange in
            guard let field = c["field"] as? String, !field.isEmpty else { throw AgentBridgeError.invalid("改动缺少字段名") }
            return ProposalChange(field: field, before: c["before"] as? String, after: c["after"] as? String)
        }
        guard let action = o["action"] as? [String: Any], action["kind"] as? String == "experimentNoop" else {
            throw AgentBridgeError.invalid("不支持的改动种类（当前只接受测试改动 experimentNoop）")
        }
        let lifetime = min(max(Double(o["lifetimeSeconds"] as? Int ?? 3600), 300), 86_400)
        return ProposalDraft(id: id, parentRef: o["parentEventId"] as? String, origin: .agent,
                             originLabel: (o["originLabel"] as? String) ?? "BetterCalendar 智能体",
                             targetDeviceId: o["targetDevice"] as? String, title: title, changes: changes, reason: reason,
                             action: .experimentNoop(note: (action["note"] as? String) ?? "智能体测试提案"),
                             experiment: true, lifetime: lifetime)
    }
}

@MainActor @Observable final class AgentBridge {
    static let bookmarkKey = "agentBridge.folderBookmark"
    private(set) var folderPath: String?
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var importedCount = 0

    private let center: ProposalCenter
    private let contextProvider: () -> [String: Any]
    private let defaults: UserDefaults
    private var loop: Task<Void, Never>?

    init(center: ProposalCenter, defaults: UserDefaults = .standard, contextProvider: @escaping () -> [String: Any]) {
        self.center = center; self.defaults = defaults; self.contextProvider = contextProvider
        folderPath = resolveFolder()?.path
    }

    var connected: Bool { folderPath != nil }

    #if os(macOS)
    /// 只由用户点击按钮触发：选择智能体工作区里的 bridge 目录。
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "选择 BetterCalendar 智能体工作区里的 bridge 文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            defaults.set(try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: Self.bookmarkKey)
            folderPath = url.path; lastError = nil
            DevLog.shared.info("智能体桥接", "已连接：\(url.path)")
            Task { await sync() }
        } catch { report("保存目录授权失败", error) }
    }
    #endif

    func disconnect() {
        defaults.removeObject(forKey: Self.bookmarkKey); folderPath = nil
        DevLog.shared.info("智能体桥接", "已断开")
    }

    /// 每 20 秒同步一次（测试环境不要启动）。
    func start(every seconds: Double = 20) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sync()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func sync() async {
        guard let url = resolveFolder() else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await sync(io: AgentBridgeIO(root: url))
    }

    /// 一轮同步（可直接用临时目录测试）。
    func sync(io: AgentBridgeIO) async {
        do {
            try io.prepare()
            try io.writeContext(contextProvider())
            let files = try io.pendingProposalFiles()
            if !files.isEmpty { await center.refresh() }
            for file in files {
                do {
                    let draft = try AgentBridgeIO.draft(from: Data(contentsOf: file))
                    if let id = draft.id, center.proposals.contains(where: { $0.id == id }) {
                        try io.move(file, to: "imported")   // 已导入过（上次崩在移动前）：幂等
                        continue
                    }
                    guard await center.submit(draft) != nil else { continue }   // 失败留在原处，下轮重试；错误已在 center 里可见
                    try io.move(file, to: "imported")
                    importedCount += 1
                } catch {
                    try? io.move(file, to: "rejected", note: error.localizedDescription)
                    report("拒绝导入智能体提案 \(file.lastPathComponent)", error)
                }
            }
            for p in center.proposals where p.origin == .agent { try io.writeResult(p, at: .now) }
            lastSync = .now
        } catch { report("桥接同步失败", error) }
    }

    // MARK: 内部

    private func resolveFolder() -> URL? {
        #if os(macOS)
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            report("目录授权已失效，请重新选择", AgentBridgeError.invalid("书签无法解析")); return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: Self.bookmarkKey)
        }
        return url
        #else
        return nil   // 智能体跑在 Mac 上；iOS 不连桥接目录
        #endif
    }

    private func report(_ what: String, _ error: Error) {
        lastError = "\(what)：\(error.localizedDescription)"
        DevLog.shared.error("智能体桥接", lastError!)
    }
}

/// 写给智能体的「今天」快照（只读副本；真相仍在 BetterCalendar）。
@MainActor enum AgentBridgeContext {
    static func snapshot(planStore: (any PlanReading)?, active: (title: String, start: Date)?, now: Date = .now) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        let day = DayContext.logicalStartOfDay(now)
        let blocks = ((try? planStore?.plannedBlocks(on: day)) ?? []).sorted { $0.start < $1.start }.map { b -> [String: Any] in
            ["title": b.title, "start": hm.string(from: b.start), "end": hm.string(from: b.end),
             "fixed": b.isFixed, "important": b.priority == .important]
        }
        var context: [String: Any] = ["schemaVersion": 1, "writtenAt": iso.string(from: now), "synthetic": false,
                                      "device": ProposalDevice.label, "deviceId": ProposalDevice.id,
                                      "today": ["logicalDayStart": iso.string(from: day), "blocks": blocks]]
        context["running"] = active.map { ["title": $0.title, "startedAt": iso.string(from: $0.start)] as [String: Any] } ?? NSNull()
        return context
    }
}
