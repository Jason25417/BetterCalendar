import Foundation
import Testing
@testable import BetterCalendar

/// W24：「当前智能体」状态标记 bridge/runtime/active-agent.json——心跳据此区分「切到内置智能体（按设计不写桥接）」与「App 没在运行」。
/// 原则 9：标记不是通道——只写这一个文件，不写 context.json / 事件、不建通道目录。
@MainActor @Suite struct W24ActiveAgentMarkerTests {
    static let at = ISO8601DateFormatter().date(from: "2026-10-19T14:00:00Z")!

    func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bc-w24-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func bridge() -> AgentBridge {
        let center = ProposalCenter(transport: InMemoryProposalTransport(), executor: ExperimentOnlyExecutor(), notifier: SilentProposalNotifier(),
                                    ledger: MemoryOperationLedger(), deviceId: "mac", deviceLabel: "Mac")
        let b = AgentBridge(center: center, defaults: UserDefaults(suiteName: "bc-w24-" + UUID().uuidString)!) { ["schemaVersion": 1] }
        b.isActive = { false }   // 内置智能体接通：桥接不是通道
        b.eventsEnabled = { true }
        return b
    }

    func allFiles(_ root: URL) -> [String] {
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var out: [String] = []
        while let u = e?.nextObject() as? URL {
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(String(u.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
            }
        }
        return out.sorted()
    }

    @Test func markerIsTheOnlyFileWrittenWhileBuiltinIsActive() async throws {
        let root = try tempRoot()
        let b = bridge()
        try b.markActiveAgent(.builtin, io: AgentBridgeIO(root: root), at: Self.at)
        await b.sync(io: AgentBridgeIO(root: root))   // 没接通：同步什么都不做
        #expect(allFiles(root) == [AgentBridgeIO.activeAgentMarkerPath])
        let o = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(AgentBridgeIO.activeAgentMarkerPath))) as? [String: Any])
        #expect(o["schemaVersion"] as? Int == 1)
        #expect(o["activeAgent"] as? String == "builtin")
        #expect(o["channel"] as? String == AppChannel.current.rawValue)
        #expect(o["writtenAt"] as? String == "2026-10-19T14:00:00Z")
        #expect(o["app"] as? String == "BetterCalendar")
        // 只有这些键：不带上下文、不带事件
        #expect(Set(o.keys) == ["schemaVersion", "app", "channel", "activeAgent", "writtenAt", "note"])
    }

    @Test func switchingBackOverwritesMarker() throws {
        let root = try tempRoot()
        let b = bridge()
        try b.markActiveAgent(.builtin, io: AgentBridgeIO(root: root), at: Self.at)
        try b.markActiveAgent(.claudeCode, io: AgentBridgeIO(root: root), at: Self.at.addingTimeInterval(60))
        let o = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(AgentBridgeIO.activeAgentMarkerPath))) as? [String: Any])
        #expect(o["activeAgent"] as? String == "claudeCode")
        #expect(o["writtenAt"] as? String == "2026-10-19T14:01:00Z")
    }

    @Test func channelMismatchWritesNothing() throws {
        let root = try tempRoot()
        let other = AppChannel.current.siblings[0]
        try Data(other.rawValue.utf8).write(to: root.appendingPathComponent(AppChannel.bridgeMarkerFile))
        #expect(throws: AgentBridgeError.self) { try bridge().markActiveAgent(.builtin, io: AgentBridgeIO(root: root), at: Self.at) }
        #expect(allFiles(root) == [AppChannel.bridgeMarkerFile])
    }

    @Test func markerShapeMatchesHeartbeatContract() {
        // 心跳（heartbeat/heartbeat.mjs readMarker）认：schemaVersion 1 + activeAgent ∈ {claudeCode, builtin} + channel ∈ {daily, dev} + 可解析的 writtenAt
        for kind in AgentKind.allCases {
            let o = AgentBridgeIO.activeAgentMarkerObject(kind, channel: .dev, at: Self.at)
            #expect(o["activeAgent"] as? String == kind.rawValue)
            #expect(o["channel"] as? String == "dev")
            #expect(ISO8601DateFormatter().date(from: o["writtenAt"] as? String ?? "") == Self.at)
        }
        #expect(Set(AgentKind.allCases.map(\.rawValue)) == ["claudeCode", "builtin"])
    }
}
