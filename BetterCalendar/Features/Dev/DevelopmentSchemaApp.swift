#if BC_SCHEMA_SEEDER && DEBUG && os(macOS)
import SwiftUI
import SwiftData
import CoreData
import CloudKit
import Security
import Observation

/// A compile-time alternate entry point. It never constructs AppContainer,
/// SharedModelContainer, collectors, timers, or the user's normal data store.
@main struct DevelopmentSchemaApp: App {
    @State private var session = DevelopmentSchemaSession()
    var body: some Scene {
        WindowGroup("BetterCalendar · Development schema") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Development schema 准备").font(.title2)
                Text(session.status).textSelection(.enabled)
                Text("独立本地库，仅合成数据；不打开日用数据库，不改 Production。")
                    .foregroundStyle(.secondary)
                if let path = session.receiptURL { Text(path.path).font(.caption).textSelection(.enabled) }
            }
            .padding(24).frame(minWidth: 600, minHeight: 200)
            .task { await session.prepare() }
        }
    }
}

@MainActor @Observable private final class DevelopmentSchemaSession {
    private(set) var status = "正在核验签名环境"
    private(set) var receiptURL: URL?
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var preparationTime: Date?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var createdTypes: [String] = []

    private func requireDevelopmentSignature() throws {
        var dynamic: SecCode?, code: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &dynamic) == errSecSuccess, let dynamic,
              SecCodeCopyStaticCode(dynamic, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.developer.icloud-container-environment"] as? String == "Development",
              (entitlements["com.apple.developer.icloud-container-identifiers"] as? [String])?.contains(AppChannel.current.cloudKitContainerID) == true else {
            throw DataArchiveError.invalid("拒绝播种：签名未证明是指定容器的 Development 环境")
        }
    }

    func prepare() async {
        guard !started else { return }; started = true
        do {
            try requireDevelopmentSignature()
            guard !TestHost.isActive else { throw DataArchiveError.invalid("测试宿主禁止云端写入") }
            guard try await CKContainer(identifier: AppChannel.current.cloudKitContainerID).accountStatus() == .available else {
                throw DataArchiveError.invalid("iCloud 账号当前不可用")
            }
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BetterCalendarSchemaSeeder/retained-deletion-v1", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            receiptURL = support.appendingPathComponent("receipt.json")
            observer = NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event, event.endDate != nil else { return }
                let exported = event.type == .export && event.succeeded
                let start = event.startDate, end = event.endDate
                let issue = event.error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let issue { self.status = "CloudKit 报错：" + issue; self.writeReceipt(phase: "cloud-error", error: issue) }
                    else if exported, let prepared = self.preparationTime, start >= prepared {
                        self.status = "Development 已收到播种后的成功导出；仍须在 Console 核验实际字段差异。"
                        self.writeReceipt(phase: "exported", exportEndedAt: end)
                    }
                }
            }
            let configuration = ModelConfiguration("DevelopmentSchemaSeeder", schema: DataArchiveStore.schema,
                url: support.appendingPathComponent("schema.store"),
                cloudKitDatabase: .private(AppChannel.current.cloudKitContainerID))
            let cloud = try ModelContainer(for: DataArchiveStore.schema, configurations: configuration)
            container = cloud
            let created = try CloudKitSchemaSeeder.seedRetainedDeletion(in: cloud.mainContext)
            try cloud.mainContext.save()
            createdTypes = created
            preparationTime = .now
            status = "已保存 \(created.count) 类合成记录，等待 Development CloudKit 导出。"
            writeReceipt(phase: "prepared", createdTypes: created)
        } catch {
            status = "播种未完成：" + error.localizedDescription
            writeReceipt(phase: "failed", error: error.localizedDescription)
        }
    }

    private func writeReceipt(phase: String, createdTypes: [String]? = nil, exportEndedAt: Date? = nil, error: String? = nil) {
        guard let receiptURL else { return }
        var value: [String: Any] = ["schemaVersion": 1, "phase": phase, "environment": "Development",
            "container": AppChannel.current.cloudKitContainerID, "updatedAt": ISO8601DateFormatter().string(from: .now),
            "expectedTypes": 5, "expectedAddedFields": 20, "createdTypes": createdTypes ?? self.createdTypes,
            "normalUserStoreOpened": false, "productionChanged": false]
        if let exportEndedAt { value["exportEndedAt"] = ISO8601DateFormatter().string(from: exportEndedAt) }
        if let error { value["error"] = error }
        do {
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: receiptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
        } catch { status = "本地证据未保存：" + error.localizedDescription }
    }
}
#endif
