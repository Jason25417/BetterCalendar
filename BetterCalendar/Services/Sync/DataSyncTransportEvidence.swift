import Foundation

/// Transport observations only. Neither opening a CloudKit store nor completing
/// an export proves that another device imported the same record.
nonisolated struct DataSyncTransportEvidence {
    enum Phase: String { case setup, `import`, export }
    enum Storage: String { case unknown, cloudKit, localOnly }
    private(set) var storage: Storage = .unknown
    private(set) var lastImport: Date?
    private(set) var lastExport: Date?
    private(set) var lastEventAt: Date?
    private(set) var lastEventPhase: Phase?
    private(set) var lastEventSucceeded: Bool?
    private(set) var lastFailureAt: Date?
    private(set) var lastFailurePhase: Phase?
    private(set) var lastFailureDomain: String?
    private(set) var lastFailureCode: Int?

    mutating func opened(cloud: Bool) { storage = cloud ? .cloudKit : .localOnly }

    mutating func finished(_ phase: Phase, at date: Date, succeeded: Bool, error: Error?) {
        // Out-of-order observer delivery must not regress the latest phase.
        if lastEventAt == nil || date >= lastEventAt! {
            lastEventAt = date; lastEventPhase = phase; lastEventSucceeded = succeeded
        }
        if succeeded {
            if phase == .import, lastImport == nil || date > lastImport! { lastImport = date }
            if phase == .export, lastExport == nil || date > lastExport! { lastExport = date }
        } else if lastFailureAt == nil || date >= lastFailureAt! {
            lastFailureAt = date; lastFailurePhase = phase
            if let error {
                let ns = error as NSError
                // Custom domains/userInfo/descriptions can contain user content.
                lastFailureDomain = ["CKErrorDomain", NSCocoaErrorDomain, NSURLErrorDomain].contains(ns.domain) ? ns.domain : "other"
                lastFailureCode = ns.code
            } else { lastFailureDomain = nil; lastFailureCode = nil }
        }
    }

    func diagnostics() -> BridgeJSON {
        let formatter = ISO8601DateFormatter()
        func time(_ value: Date?) -> BridgeJSON { .text(value.map(formatter.string(from:))) }
        return .object([
            "version": .number(1), "storage": .string(storage.rawValue),
            "lastImportAt": time(lastImport), "lastExportAt": time(lastExport),
            "lastEventAt": time(lastEventAt), "lastEventPhase": .text(lastEventPhase?.rawValue),
            "lastEventSucceeded": lastEventSucceeded.map(BridgeJSON.bool) ?? .null,
            "lastFailureAt": time(lastFailureAt), "lastFailurePhase": .text(lastFailurePhase?.rawValue),
            "lastFailureDomain": .text(lastFailureDomain),
            "lastFailureCode": lastFailureCode.map { .number(Double($0)) } ?? .null,
            "coverage": .string("this_process_lifetime_not_complete_history"),
            "otherDeviceApplied": .string("unknown")
        ])
    }
}
