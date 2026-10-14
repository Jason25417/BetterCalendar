import Foundation

/// Same native layout and decision client, in-memory transport only. This
/// service has no production credentials, writer, notifications or executor.
@MainActor enum NativeApprovalPreview {
    static func make() -> NativeApprovalInbox {
        let prefs = UserDefaults(suiteName: "bc-approval-display-" + UUID().uuidString)!
        return NativeApprovalInbox(service: DisplayService(), persistence: NativeApprovalMemoryPersistence(), preferences: prefs, mayApprove: { _ in true }, isDisplayTest: true)
    }
    private final class DisplayService: NativeRemoteServing {
        let nativeDeviceId: String? = "display-only"
        let id = "12345678-1234-4234-8234-000000003900"
        let at = Date()
        var state = "awaiting_confirmation"
        func envelope() throws -> BridgeJSON {
            let request: BridgeJSON = .object(["version": .number(1), "commandId": .string(id), "deviceId": .string("display-only"),
                "kind": .string("item"), "action": .string("update"), "recordId": .string("12345678-1234-4234-8234-000000003901"),
                "expectedRevision": .string("display-only-revision"), "patch": .object(["note": .string("BC 审批显示测试；不会保存到任何事项")]),
                "occurredAt": NativeRemoteJSON.timestamp(at), "expiresAt": NativeRemoteJSON.timestamp(at.addingTimeInterval(86400)),
                "userRequest": .string("Only inspect native approval layout; no real task or execution")])
            return .object(["version": .number(1), "nativeCommandId": .string(id), "commandId": .string(id), "deviceId": .string("display-only"),
                "requestHash": .string(BridgePoolCodec.hash(try BridgePoolCodec.encode(request))), "request": request,
                "grantRevision": .number(1), "state": .string(state), "expiresAt": NativeRemoteJSON.timestamp(at.addingTimeInterval(86400)),
                "serverAccepted": .bool(true), "approvedAt": state == "queued" ? NativeRemoteJSON.timestamp(at) : .null,
                "display": .object(["recordTitle": .string("演示事项（不会保存）"), "deviceLabel": .string("当前设备（显示测试）"), "before": .object(["note": .string("")])]),
                "result": .object(["executed": .bool(false), "operationEffect": .string("read_only_display")])])
        }
        func nativeRequest(_ path: String, body: BridgeJSON) async throws -> BridgeJSON {
            switch path {
            case "native/approvals": return .object(["commands": .array(state == "awaiting_confirmation" ? [try envelope()] : []), "through": .string(id), "nextCursor": state == "awaiting_confirmation" ? .string(id) : (try NativeRemoteJSON.object(body)["after"] ?? .string("")), "hasMore": .bool(false)])
            case "native/approval/read": return try envelope()
            case "native/approval/decide":
                let data = try NativeRemoteJSON.object(body), decision = try NativeRemoteJSON.string(data["decision"])
                guard data["commandId"] == .string(id), data["requestHash"] == (try NativeRemoteJSON.object(envelope())["requestHash"]), ["accept", "decline"].contains(decision) else { throw DataArchiveError.invalid("显示测试身份无效") }
                if state == "awaiting_confirmation" { state = decision == "accept" ? "queued" : "declined" }
                return try envelope()
            default: throw DataArchiveError.invalid("显示测试无此操作；没有生产连接")
            }
        }
    }
}
