import Foundation
import CryptoKit

nonisolated struct NativeEvidenceCapture: Sendable {
    let data: Data
    let includedFiles: Int
    let unavailableFiles: Int
}

/// Read-only snapshots of the execution journals. Never reads connection
/// configuration, credentials, the SwiftData store or photo files.
nonisolated enum NativeEvidenceExport {
    static let sources: [(String, Int)] = [
        ("native-remote-v1.json", 16 * 1024 * 1024),
        ("native-actions-v1.json", 4 * 1024 * 1024),
        ("task-commands-v1.json", 4 * 1024 * 1024)
    ]

    static func capture(root: URL, at: Date = Date(), byteLimit: Int? = nil) throws -> NativeEvidenceCapture {
        var entries: [[String: Any]] = [], included = 0, unavailable = 0
        for (name, normalLimit) in sources {
            let url = root.appendingPathComponent(name), limit = min(normalLimit, byteLimit ?? normalLimit)
            var entry: [String: Any] = ["file": name, "snapshotAt": timestamp(Date()), "readLimitBytes": limit]
            do {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    entry["status"] = "not_present"; entries.append(entry); unavailable += 1; continue
                }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    entry["status"] = "unsupported_file_type"; entries.append(entry); unavailable += 1; continue
                }
                entry["modifiedAt"] = values.contentModificationDate.map(timestamp)
                entry["reportedBytes"] = values.fileSize
                guard let size = values.fileSize, size <= limit else {
                    entry["status"] = "too_large_original_retained"; entries.append(entry); unavailable += 1; continue
                }
                let bytes = try Data(contentsOf: url)
                guard bytes.count <= limit else {
                    entry["status"] = "too_large_original_retained"; entries.append(entry); unavailable += 1; continue
                }
                entry["readBytes"] = bytes.count
                entry["originalSHA256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                do {
                    let original = try JSONSerialization.jsonObject(with: bytes)
                    guard original is [String: Any] || original is [Any] else { throw CocoaError(.propertyListReadCorrupt) }
                    var redactions = 0
                    let content = try redact(original, depth: 0, count: &redactions)
                    entry["content"] = content; entry["redactions"] = redactions
                    entry["status"] = "snapshot_included"; included += 1
                } catch {
                    // A damaged or excessively nested file stays untouched.
                    // Raw invalid text is not exported because it cannot be
                    // checked for credential fields reliably.
                    entry["status"] = "unreadable_json_original_retained"; unavailable += 1
                }
            } catch {
                entry["status"] = "read_failed_original_retained"
                entry["errorDomain"] = (error as NSError).domain
                entry["errorCode"] = (error as NSError).code
                unavailable += 1
            }
            entries.append(entry)
        }
        let report: [String: Any] = [
            "schemaVersion": 1, "exportedAt": timestamp(at),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "purpose": "local_execution_evidence_not_backup_or_restore",
            "atomicAcrossFiles": false, "liveSourceUnchanged": true,
            "redaction": "credential fields and recognizable credential text removed; original hashes describe source bytes, not sanitized content",
            "coverage": ["includedFiles": included, "unavailableFiles": unavailable,
                         "deviceAppliedOrUserSeen": "not_inferred_from_export",
                         "semanticValidation": "not_performed_by_export",
                         "excluded": ["connection configuration", "credential files", "SwiftData database", "photo binaries", "other device files", "cloud-only research logs"]] as [String: Any],
            "files": entries
        ]
        return .init(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]),
                     includedFiles: included, unavailableFiles: unavailable)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func redact(_ value: Any, depth: Int, count: inout Int) throws -> Any {
        guard depth <= 64 else { throw CocoaError(.propertyListReadCorrupt) }
        if let fields = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in fields {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                let tokenMetric = ["inputtokens", "outputtokens", "totaltokens", "tokencount"].contains(normalized) && child is NSNumber
                let secret = !tokenMetric && ["token", "secret", "password", "credential", "cookie", "apikey", "privatekey", "privatereasoning", "chainofthought", "reasoningcontent"].contains { normalized.contains($0) }
                // Preserve ordinary system authorization status, not headers.
                let authorizationStatus = (child as? String).map { ["authorized", "denied", "not_determined", "unknown"].contains($0) } ?? false
                if secret || (normalized == "authorization" && !authorizationStatus) {
                    result[key] = "[redacted]"; count += 1
                } else { result[key] = try redact(child, depth: depth + 1, count: &count) }
            }
            return result
        }
        if let list = value as? [Any] { return try list.map { try redact($0, depth: depth + 1, count: &count) } }
        if var text = value as? String {
            for pattern in [#"(?i)\bBearer\s+\S+"#, #"\b(?:sk-[A-Za-z0-9_-]{12,}|whsec_[A-Za-z0-9+/=_-]+)"#,
                            #"(?s)-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----.*?-----END (?:[A-Z ]+ )?PRIVATE KEY-----"#] {
                let expression = try NSRegularExpression(pattern: pattern)
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                count += expression.numberOfMatches(in: text, range: range)
                text = expression.stringByReplacingMatches(in: text, range: range, withTemplate: "[redacted]")
            }
            let query = try NSRegularExpression(pattern: #"(?i)([?&](?:token|access_token|deviceToken|platformToken|api_key|secret|password)=)[^&#\s]+"#)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            count += query.numberOfMatches(in: text, range: range)
            text = query.stringByReplacingMatches(in: text, range: range, withTemplate: "$1[redacted]")
            return text
        }
        return value
    }
}
