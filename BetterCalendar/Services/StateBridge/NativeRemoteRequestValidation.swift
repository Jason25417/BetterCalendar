import Foundation

/// Preflight the complete offered page before claiming any request. This checks
/// shape and supported fields; store revisions, authorization and system state
/// are still checked at the execution boundary and are never inferred here.
nonisolated enum NativeRemoteRequestValidation {
    static func validate(_ r: [String: BridgeJSON], expiresAt: BridgeJSON?) throws {
        let kind = try NativeRemoteJSON.string(r["kind"]), action = try NativeRemoteJSON.string(r["action"])
        let common: Set<String> = ["version", "commandId", "deviceId", "kind", "action", "occurredAt", "expiresAt", "userRequest"]
        try require(text(r["deviceId"], 80) && text(r["userRequest"], 2000) && r["expiresAt"] == expiresAt)
        _ = try NativeRemoteJSON.date(r["expiresAt"])
        var fields = Set<String>()
        switch kind {
        case "item":
            fields = ["recordId", "expectedRevision", "patch"]
            try require(uuid(r["recordId"]))
            let patch = try NativeRemoteJSON.object(r["patch"] ?? .object([:]))
            try require(Set(patch.keys).isSubset(of: ["title", "note", "status"]))
            if let title = patch["title"] { try require(text(title, 500)) }
            if let note = patch["note"] { try require(stringWithin(note, 16000)) }
            if let status = patch["status"] { try require(["active", "done", "shelved"].contains(try NativeRemoteJSON.string(status))) }
            if action == "create" {
                try require((r["expectedRevision"] == nil || r["expectedRevision"] == .null) && text(patch["title"], 500))
            } else {
                try require(text(r["expectedRevision"], 150))
                if action == "delete" || action == "restore" { try require(patch.isEmpty) }
            }
        case "reminder":
            try require(["read", "schedule", "update", "cancel"].contains(action))
            if action == "read" {
                fields = ["query"]
                let query = try NativeRemoteJSON.object(r["query"] ?? .object([:]))
                try require(Set(query.keys).isSubset(of: ["reminderId", "includeCancelled", "limit", "cursor"]))
                if let id = query["reminderId"] { try require(uuid(id)) }
                if let flag = query["includeCancelled"] { guard case .bool = flag else { throw invalid() } }
                if let limit = query["limit"] { try require((1...20).contains(try NativeRemoteJSON.integer(limit))) }
                if let cursor = query["cursor"] { try require(stringWithin(cursor, 2000)) }
            } else {
                fields = ["reminderId", "expectedRevision"]
                try require(uuid(r["reminderId"]))
                if action == "schedule" { try require(r["expectedRevision"] == nil) }
                else { try require((try NativeRemoteJSON.string(r["expectedRevision"])).range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil) }
                if action != "cancel" {
                    fields.formUnion(["title", "body", "fireAt", "sound", "experiment"])
                    try require(text(r["title"], 150) && stringWithin(r["body"] ?? .null, 2000))
                    _ = try NativeRemoteJSON.date(r["fireAt"])
                    guard case .bool = r["sound"], case .bool = r["experiment"] else { throw invalid() }
                }
            }
        case "alarm":
            if action == "schedule" {
                fields = ["fireAt", "title"]
                try require(text(r["title"], 150)); _ = try NativeRemoteJSON.date(r["fireAt"])
            } else {
                fields = ["alarmId"]; try require(uuid(r["alarmId"]))
            }
        case "journal":
            if action == "read" {
                fields = ["query"]
                let q = try NativeRemoteJSON.object(r["query"] ?? .object([:]))
                try require(Set(q.keys).isSubset(of: ["start", "end", "text", "includeTrash", "limit", "cursor"]))
                let start = try q["start"].map { try NativeRemoteJSON.date($0) }
                let end = try q["end"].map { try NativeRemoteJSON.date($0) }
                if let start, let end { try require(start < end) }
                if let value = q["text"] { try require(stringWithin(value, 1000)) }
                if let value = q["includeTrash"] { guard case .bool = value else { throw invalid() } }
                if let value = q["limit"] { try require((1...50).contains(try NativeRemoteJSON.integer(value))) }
                if let value = q["cursor"] { try require(stringWithin(value, 2000)) }
            } else {
                fields = ["recordId", "expectedRevision", "patch", "entryDate"]
                try require(uuid(r["recordId"]))
                if action == "create" {
                    try require(r["expectedRevision"] == nil || r["expectedRevision"] == .null)
                    _ = try NativeRemoteJSON.date(r["entryDate"])
                } else {
                    try require(text(r["expectedRevision"], 150) && r["entryDate"] == nil)
                }
                let patch = try NativeRemoteJSON.object(r["patch"] ?? .object([:]))
                try require(!patch.isEmpty && Set(patch.keys).isSubset(of: ["body", "mood", "tags"]))
                if let body = patch["body"] {
                    guard case let .string(text) = body, text.utf8.count <= 16000 else { throw invalid() }
                }
                if let mood = patch["mood"] { try require(mood == .null || stringWithin(mood, 100)) }
                if let tags = patch["tags"] {
                    guard case let .array(values) = tags, values.count <= 30, values.allSatisfy({ text($0, 100) }) else { throw invalid() }
                }
            }
        case "timer":
            if action == "start" {
                fields = ["title", "relatedRecordId", "effectiveAt", "mode", "focusMinutes", "experiment"]
                let mode = try r["mode"].map { try NativeRemoteJSON.string($0) } ?? "light"
                try require(["light", "pomodoro"].contains(mode))
                if mode == "pomodoro" { try require((1...240).contains(try NativeRemoteJSON.integer(r["focusMinutes"]))) }
                else { try require(r["focusMinutes"] == nil) }
                if let flag = r["experiment"] { guard case .bool = flag else { throw invalid() } }
                try require(text(r["title"], 300))
                if let related = r["relatedRecordId"] { try require(text(related, 150)) }
            } else {
                fields = ["sessionId", "expectedRevision", "effectiveAt"]
                try require(text(r["sessionId"], 80) && (try NativeRemoteJSON.integer(r["expectedRevision"])) >= 1)
            }
            if let effective = r["effectiveAt"] { _ = try NativeRemoteJSON.date(effective) }
        default: throw invalid()
        }
        try require(Set(r.keys).isSubset(of: common.union(fields)))
    }
    private static func text(_ value: BridgeJSON?, _ max: Int) -> Bool {
        guard case let .string(text) = value else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= max
    }
    private static func stringWithin(_ value: BridgeJSON, _ max: Int) -> Bool {
        guard case let .string(text) = value else { return false }; return text.utf16.count <= max
    }
    private static func uuid(_ value: BridgeJSON?) -> Bool {
        guard case let .string(text) = value else { return false }; return UUID(uuidString: text) != nil
    }
    private static func require(_ condition: Bool) throws { if !condition { throw invalid() } }
    private static func invalid() -> DataArchiveError { .invalid("请求字段不完整或不受支持，未执行整页；原请求需核对") }
}
