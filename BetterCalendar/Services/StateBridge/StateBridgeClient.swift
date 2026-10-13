import Foundation
import Security
import Observation

// Separate from SwiftData/CloudKit: telemetry and Dot timing do not migrate the calendar store.
nonisolated enum BridgeJSON: Codable, Equatable, Sendable {
    case object([String: BridgeJSON]), array([BridgeJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([BridgeJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: BridgeJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    static func text(_ value: String?) -> BridgeJSON { value.map(BridgeJSON.string) ?? .null }
}
struct BridgeCredentials: Codable {
    var siteURL: String
    var platformToken: String
    var deviceToken: String
    var deviceId: String
}
struct BridgeObservation: Codable {
    var schemaVersion = 1
    var eventId: String
    var source: String
    var sequence: Int
    var observedAt: String
    var expiresAt: String?
    var assertion = "observed"
    var value: BridgeJSON
}
struct BridgeOutbox: Codable {
    var nextSequence = 1
    var observations: [BridgeObservation] = []
    var poolCache: BridgePoolCache?
    func validate() throws {
        try poolCache?.validate()
        guard nextSequence > 0, observations.allSatisfy({ $0.schemaVersion == 1 && $0.sequence > 0 && $0.sequence < nextSequence }),
              Set(observations.map(\.eventId)).count == observations.count,
              Set(observations.map(\.sequence)).count == observations.count else {
            throw NSError(domain:"StateBridge.Queue",code:1,userInfo:[NSLocalizedDescriptionKey:"上传队列序号或事件身份不一致"])
        }
    }
}
private final class BridgeNoRedirect: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor @Observable final class StateBridgeClient {
    static let shared = StateBridgeClient()
    private(set) var status = "尚未配置"
    private(set) var lastUpload: Date?
    private(set) var pendingCount = 0
    private var outbox = BridgeOutbox()
    private var busy = false
    private var queueHealthy = true
    private var lastFailure: String?
    private var credentials: BridgeCredentials?
    private let delegate = BridgeNoRedirect()
    @ObservationIgnored private lazy var session: URLSession = { let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 20; return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil) }()
    private var location: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DotStateBridge/outbox-v1.json") }
    private let account = "dot-state-bridge-v1"
    var configured: Bool { credentials != nil }
    private init() {
        guard !TestHost.isActive else { return }
        do { if FileManager.default.fileExists(atPath: location.path) { outbox = try JSONDecoder().decode(BridgeOutbox.self, from: Data(contentsOf: location)); try outbox.validate() }; pendingCount = outbox.observations.count }
        catch { queueHealthy = false; reportFailure("本地队列读取失败，已保留原文件；请检查后再启用") }
        lastUpload = UserDefaults.standard.object(forKey:"dotStateBridge.lastUpload") as? Date
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"com.jason.BetterCalendar.StateBridge", kSecAttrAccount as String:account, kSecReturnData as String:true]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            credentials = try? JSONDecoder().decode(BridgeCredentials.self, from:data)
            if credentials == nil { reportFailure("凭据读取失败，请检查本机连接配置") }
            else if queueHealthy { status = "已配置，等待采集" }
        }
    }
    func configure(_ text: String) throws {
        guard !TestHost.isActive else { return }
        guard queueHealthy else { throw NSError(domain:"StateBridge",code:3,userInfo:[NSLocalizedDescriptionKey:"本地队列有损坏，请保留原文件并修复后再连接"]) }
        let c = try JSONDecoder().decode(BridgeCredentials.self, from:Data(text.utf8))
        guard let url = URL(string:c.siteURL), url.scheme == "https", url.host?.hasSuffix(".chatgpt.site") == true, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/", !c.deviceToken.isEmpty, !c.platformToken.isEmpty else { throw NSError(domain:"StateBridge",code:1,userInfo:[NSLocalizedDescriptionKey:"需要私有接入站点的 HTTPS 地址和设备凭据"]) }
        if let prior = credentials, prior.deviceId != c.deviceId, !outbox.observations.isEmpty { throw NSError(domain:"StateBridge",code:2,userInfo:[NSLocalizedDescriptionKey:"旧设备还有待上传记录，请先上传完再更换设备"]) }
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.jason.BetterCalendar.StateBridge",kSecAttrAccount as String:account]
        let data = try JSONEncoder().encode(c)
        var result = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if result == errSecItemNotFound { var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; result = SecItemAdd(add as CFDictionary,nil) }
        guard result == errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(result)) }
        credentials = c; status = "凭据已保存到本机 Keychain"
    }
    @discardableResult func emit(_ source: String, value: BridgeJSON, validFor: TimeInterval = 180, observedAt: Date = Date()) -> Bool {
        guard configured, queueHealthy, !TestHost.isActive else { return false }
        let formatter = ISO8601DateFormatter()
        let observation = BridgeObservation(eventId:UUID().uuidString,source:source,sequence:outbox.nextSequence,observedAt:formatter.string(from:observedAt),expiresAt:formatter.string(from:observedAt.addingTimeInterval(validFor)),value:value)
        guard let encoded = try? JSONEncoder().encode(observation), encoded.count < 48*1024 else { reportFailure("观察内容过大或格式无效，未写入上传队列"); return false }
        var next = outbox; next.nextSequence += 1; next.observations.append(observation)
        do { try persist(next); outbox = next; pendingCount = next.observations.count; return true }
        catch { reportFailure("保存观察失败；没有标记为已上传"); return false }
    }
    func publishPool(_ snapshot: BridgePoolSnapshot, observedAt: Date) {
        guard let credentials, queueHealthy, !TestHost.isActive else { return }
        var next = outbox
        do {
            try next.enqueuePool(snapshot, deviceId: credentials.deviceId, at: observedAt)
            try persist(next); outbox = next; pendingCount = next.observations.count
        } catch { reportFailure("事项目录排队失败，原记录及上一份目录保留") }
    }
    private func reportFailure(_ message: String) {
        status = message
        if lastFailure != message { DevLog.shared.warn("StateBridge",message); lastFailure = message }
    }
    private func persist(_ value: BridgeOutbox) throws {
        try FileManager.default.createDirectory(at:location.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(value).write(to:location,options:.atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:location.path)
        #endif
    }
    private func post(_ path: String, body: Data) async throws -> [String:Any] {
        guard let c = credentials, let base = URL(string:c.siteURL) else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url:base.appendingPathComponent("api/" + path)); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("Bearer " + c.platformToken,forHTTPHeaderField:"OAI-Sites-Authorization")
        request.setValue("Bearer " + c.deviceToken,forHTTPHeaderField:"Authorization")
        let (data,response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw NSError(domain:"StateBridge.HTTP",code:http.statusCode) }
        return (try JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
    }
    func readTasks() async throws -> BridgeTaskState {
        let result = try await post("tasks/state",body:Data("{}".utf8))
        return try BridgeTaskCodec.networkDecoder().decode(BridgeTaskState.self,from:JSONSerialization.data(withJSONObject:result))
    }
    func submitTask(_ command: BridgeTaskCommand) async throws -> BridgeTaskReceipt {
        let result = try await post("tasks/command",body:try BridgeTaskCodec.networkEncoder().encode(command))
        return try BridgeTaskCodec.networkDecoder().decode(BridgeTaskReceipt.self,from:JSONSerialization.data(withJSONObject:result))
    }
    func reportSavedTaskSnapshots(_ ids: [String]) async throws -> Set<String> {
        let result = try await post("tasks/applied", body: JSONSerialization.data(withJSONObject: ["snapshotIds": ids]))
        guard result["recorded"] as? Bool == true, let accepted = result["accepted"] as? [String],
              Set(accepted) == Set(ids) else { throw URLError(.cannotParseResponse) }
        return Set(accepted)
    }
    func uploadAndFlush() async {
        guard configured, queueHealthy, !busy, !TestHost.isActive else { return }; busy = true; defer { busy = false }
        do {
            // Small batches stay below the request limit. Preserve concurrently appended observations.
            while !outbox.observations.isEmpty {
                let poolSources = ["bc.pool", "bc.pool.chunk"]
                let isPool = poolSources.contains(outbox.observations[0].source)
                let sent = Array(outbox.observations.prefix(4).prefix { poolSources.contains($0.source) == isPool })
                struct Payload: Encodable { let observations: [BridgeObservation] }
                let result = try await post(isPool ? "pool/upload" : "ingest",body:try JSONEncoder().encode(Payload(observations:sent)))
                let acknowledged = Set((result["accepted"] as? [String] ?? []) + (result["ignored"] as? [String] ?? []))
                guard sent.allSatisfy({ acknowledged.contains($0.eventId) }) else { throw URLError(.cannotParseResponse) }
                var next = outbox; next.observations.removeAll { acknowledged.contains($0.eventId) }; try persist(next); outbox = next; pendingCount = next.observations.count
            }
            let result = try await post("flush",body:Data("{}".utf8))
            lastUpload = Date(); UserDefaults.standard.set(lastUpload,forKey:"dotStateBridge.lastUpload"); lastFailure = nil
            status = (result["activeSubscriptions"] as? Int ?? 0) > 0 ? "状态已保存；等待 Dot 处理" : "状态已保存，Dot 事件订阅尚未连接"
        } catch {
            let failure = error as NSError
            let reason = failure.domain == "StateBridge.HTTP" ? "服务返回 HTTP \(failure.code)" : "网络或响应异常（\(failure.code)）"
            reportFailure("\(reason)；保留 \(outbox.observations.count) 条观察等待重试")
        }
    }
}

extension StateBridgeClient: BridgeTaskServing {}
