import Foundation
import Testing
@testable import BetterCalendar

/// Isolated setup fixtures: never touch Keychain, network, actual journals or alarms.
@MainActor @Suite struct NativeConversationPermissionsTests {
    private func fixture(supported: Bool = true) -> (NativeActionsViewModel, PermissionService, PermissionAlarms, PermissionData, NativeRemoteMemoryPersistence) {
        let service = PermissionService(), alarms = PermissionAlarms(), data = PermissionData()
        alarms.capability = .init(supported: supported, authorization: supported ? "not_determined" : "unsupported")
        let persistence = NativeRemoteMemoryPersistence()
        let tasks = BridgeTaskViewModel(service: data, persistence: BridgeTaskMemoryPersistence(), enabled: { true })
        let remote = NativeRemoteExecutor(service: service, persistence: persistence, writer: data, alarms: alarms, journal: data, canonicalTasks: tasks)
        return (NativeActionsViewModel(writer: data, alarms: alarms, remote: remote), service, alarms, data, persistence)
    }
    @Test func explicitSetupGrantsAllSupportedScopesWithoutAnyOperation() async throws {
        let (model, service, alarms, data, persistence) = fixture()
        await model.enableAllConversationCapabilities()
        let grant = try #require(persistence.file.grant)
        #expect(grant.synchronized && Set(grant.capabilities) == Set([
            "item.create", "item.update", "item.delete", "item.restore",
            "alarm.schedule", "alarm.cancel", "journal.read", "journal.create", "journal.update",
            "timer.start", "timer.pause", "timer.resume", "timer.finish"
        ]))
        #expect(alarms.authorizationCalls == 1 && alarms.operations == 0 && data.operations == 0)
        #expect(service.paths == ["native/grant/read", "native/grant"])
        #expect(model.remote?.allowAlarms == true && model.remote?.allowTimer == true)
        #expect(model.conversationSetupNotice?.contains("全部对话权限已保存") == true)
        // Already-authorized repeat setup must not ask the system again.
        await model.enableAllConversationCapabilities()
        #expect(alarms.authorizationCalls == 1 && persistence.file.grant?.revision == 2)
        #expect(alarms.operations == 0 && data.operations == 0)
    }
    @Test func deniedSystemAlarmStillSavesOtherScopesAndReportsPartialResult() async throws {
        let (model, _, alarms, data, persistence) = fixture()
        alarms.authorizationResult = "denied"
        await model.enableAllConversationCapabilities()
        let grant = try #require(persistence.file.grant)
        #expect(grant.synchronized && grant.capabilities.count == 11)
        #expect(!grant.capabilities.contains(where: { $0.hasPrefix("alarm.") }))
        #expect(model.remote?.allowAlarms == false && model.remote?.allowItems == true)
        #expect(model.conversationSetupNotice?.contains("闹钟权限未开启") == true)
        #expect(alarms.operations == 0 && data.operations == 0)
    }
    @Test func unsupportedPlatformSkipsSystemPrompt() async {
        let (model, _, alarms, data, persistence) = fixture(supported: false)
        await model.enableAllConversationCapabilities()
        #expect(alarms.authorizationCalls == 0 && persistence.file.grant?.capabilities.count == 11)
        #expect(model.remote?.allowAlarms == false && model.remote?.allowTimer == true)
        #expect(alarms.operations == 0 && data.operations == 0)
    }
    @Test func missingConnectionHasVisibleReasonWithoutRequestingAnyPermissions() async {
        let (model, service, alarms, _, persistence) = fixture()
        service.nativeDeviceId = nil
        await model.enableAllConversationCapabilities()
        #expect(service.paths.isEmpty && alarms.authorizationCalls == 0 && persistence.file.grant == nil)
        #expect(model.conversationSetupNotice?.contains("尚未保存连接") == true)
    }
    @Test func systemErrorOrChangedDeviceDoesNotGrant() async {
        for changedDevice in [false, true] {
            let (model, service, alarms, _, persistence) = fixture()
            if changedDevice { alarms.onAuthorize = { service.nativeDeviceId = "different-fixture-device" } }
            else { alarms.authorizationFails = true }
            await model.enableAllConversationCapabilities()
            #expect(service.paths.isEmpty && persistence.file.grant == nil && !model.working)
            #expect(model.conversationSetupNotice?.contains(changedDevice ? "连接在授权期间改变" : "系统闹钟授权失败") == true)
        }
    }
    @Test func lostGrantResponseDoesNotClaimSavedAndCanRetry() async {
        let (model, service, alarms, data, persistence) = fixture()
        service.loseGrantResponse = true
        await model.enableAllConversationCapabilities()
        #expect(persistence.file.grant?.synchronized == false)
        #expect(model.remote?.allowItems == false && model.remote?.allowTimer == false)
        #expect(model.conversationSetupNotice?.contains("尚未保存成功") == true)
        service.loseGrantResponse = false
        await model.enableAllConversationCapabilities()
        #expect(persistence.file.grant?.synchronized == true && persistence.file.grant?.revision == 2)
        #expect(model.remote?.allowItems == true && model.remote?.allowAlarms == true)
        #expect(alarms.authorizationCalls == 1 && alarms.operations == 0 && data.operations == 0)
    }
}

@MainActor private final class PermissionService: NativeRemoteServing {
    var nativeDeviceId: String? = "isolated-permission-fixture"
    var paths: [String] = []
    var revision = 0
    var loseGrantResponse = false
    func nativeRequest(_ path: String, body: BridgeJSON) async throws -> BridgeJSON {
        paths.append(path)
        if path == "native/grant/read" { return .object(["revision": .number(Double(revision))]) }
        guard path == "native/grant" else { throw URLError(.unsupportedURL) }
        revision = try NativeRemoteJSON.integer(NativeRemoteJSON.object(body)["revision"])
        if loseGrantResponse { throw URLError(.networkConnectionLost) }
        return .object(["revision": .number(Double(revision))])
    }
}
@MainActor private final class PermissionAlarms: NativeAlarmScheduling {
    var capability = NativeAlarmCapability(supported: true, authorization: "not_determined")
    var authorizationResult = "authorized"
    var authorizationCalls = 0
    var authorizationFails = false
    var onAuthorize: (() -> Void)?
    var operations = 0
    func inspect() -> NativeAlarmCapability { capability }
    func requestAuthorization() async throws -> NativeAlarmCapability {
        authorizationCalls += 1; onAuthorize?()
        if authorizationFails { throw URLError(.unknown) }
        capability.authorization = authorizationResult; return capability
    }
    func schedule(_ request: NativeAlarmRequest, userConfirmed: Bool) async throws -> BridgeJSON { operations += 1; return .null }
    func cancel(commandId: UUID, alarmId: UUID, userConfirmed: Bool) throws -> BridgeJSON { operations += 1; return .null }
    func recordedAlarms() throws -> [NativeAlarmRequest] { [] }
}
@MainActor private final class PermissionData: NativeItemWriting, NativeJournalAccessing, BridgeTaskServing {
    var operations = 0
    func records() throws -> [NativePoolRecord] { [] }
    func execute(_ command: NativeItemCommand, userConfirmed: Bool) throws -> BridgeJSON { operations += 1; return .null }
    func read(_ query: NativeJournalQuery, readAllowed: Bool) throws -> BridgeJSON { operations += 1; return .null }
    func execute(_ command: NativeJournalCommand, userConfirmed: Bool) throws -> BridgeJSON { operations += 1; return .null }
    func readTasks() async throws -> BridgeTaskState { operations += 1; throw URLError(.unsupportedURL) }
    func submitTask(_ command: BridgeTaskCommand) async throws -> BridgeTaskReceipt { operations += 1; throw URLError(.unsupportedURL) }
}
