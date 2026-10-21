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
    /// 0.72.1：最近一次导出失败是不是「服务器拒收」类（重试也不会好）。
    private(set) var lastExportFailureFatal = false
    private(set) var lastExportFailureAt: Date?

    /// 服务器拒收类的 CloudKit 错误：部分失败（批量原子，一条坏记录拖垮整批）/ 参数无效（schema 缺字段）/
    /// 请求被拒 / 配额满。网络、系统延后（134419）、限流这些会自己好，不算。
    nonisolated static let fatalExportCodes: Set<Int> = [2, 12, 15, 25]

    /// 同步通道卡死：最近一次导出被服务器拒收、之后还没有导出成功过。
    /// 此时本机既发不出去，NSPersistentCloudKitContainer 也不再导入（"Not reviving the mirroring delegate"）
    /// ——本机真相随时可能落后另一台设备，不能拿它去判「日历上的变化是你的手改」或去盖另一台设备的画面。
    var isWedged: Bool {
        guard lastExportFailureFatal, let failed = lastExportFailureAt else { return false }
        return lastExport.map { $0 < failed } ?? true
    }

    mutating func opened(cloud: Bool) { storage = cloud ? .cloudKit : .localOnly }

    mutating func finished(_ phase: Phase, at date: Date, succeeded: Bool, error: Error?) {
        // Out-of-order observer delivery must not regress the latest phase.
        if lastEventAt == nil || date >= lastEventAt! {
            lastEventAt = date; lastEventPhase = phase; lastEventSucceeded = succeeded
        }
        if succeeded {
            if phase == .import, lastImport == nil || date > lastImport! { lastImport = date }
            if phase == .export, lastExport == nil || date > lastExport! { lastExport = date }
        } else if phase == .export, lastExportFailureAt == nil || date >= lastExportFailureAt! {
            lastExportFailureAt = date
            let ns = error.map { $0 as NSError }
            lastExportFailureFatal = ns.map { $0.domain == "CKErrorDomain" && Self.fatalExportCodes.contains($0.code) } ?? false
        }
        if !succeeded, lastFailureAt == nil || date >= lastFailureAt! {
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
            "wedged": .bool(isWedged),
            "coverage": .string("this_process_lifetime_not_complete_history"),
            "otherDeviceApplied": .string("unknown")
        ])
    }
}
