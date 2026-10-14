import Foundation
import Testing
import SwiftUI
#if os(macOS)
import AppKit
#endif
@testable import BetterCalendar

@MainActor @Suite struct NativeApprovalInboxTests {
    let at = Date(timeIntervalSince1970: 1791885600)
    private func fixture() throws -> (ApprovalService, NativeApprovalMemoryPersistence, UserDefaults) {
        let prefs = UserDefaults(suiteName: "bc-approval-fixture-" + UUID().uuidString)!
        return (try ApprovalService(at: at), NativeApprovalMemoryPersistence(), prefs)
    }
    private func model(_ service: ApprovalService, _ disk: any NativeApprovalPersisting, _ prefs: UserDefaults,
                       notifier: ApprovalNotifier? = nil) -> NativeApprovalInbox {
        NativeApprovalInbox(service: service, persistence: disk, notifier: notifier, preferences: prefs, now: { self.at }, mayApprove: { _ in true })
    }
    @Test func openingAndRefreshingNeverApprovesAndDoesNotAskForNotificationPermission() async throws {
        let (service, disk, prefs) = try fixture(); let notifications = ApprovalNotifier(), inbox = model(service, disk, prefs, notifier: notifications)
        await inbox.refresh(); await inbox.open(service.id)
        #expect(inbox.displayTestDecision == nil)
        #expect(inbox.pending.count == 1 && inbox.readComplete && inbox.selected?.state == "awaiting_confirmation")
        #expect(service.decisions.isEmpty && notifications.authorizations == 0 && notifications.sent.isEmpty && disk.values.isEmpty)
    }
    @Test func lostApprovalReplyKeepsExactDecisionAcrossRestartAndNeverClaimsApplied() async throws {
        let (service, disk, prefs) = try fixture(); let inbox = model(service, disk, prefs)
        await inbox.open(service.id); service.loseResponse = true
        await inbox.decide("accept")
        #expect(disk.values.count == 1 && inbox.selected?.state == "queued")
        let original = try #require(disk.values.first?.body)
        let restarted = model(service, disk, prefs); await restarted.refresh()
        #expect(restarted.retryCommandIds == [service.id] && restarted.selected?.state == "queued")
        #expect(service.decisions.count == 1) // Opening does not silently resend.
        await restarted.retryOriginalDecision()
        #expect(service.decisions == [original, original] && service.approvals == 1)
        #expect(disk.values.isEmpty && restarted.selected?.state == "queued")
        #expect(restarted.message?.contains("等待设备") == true)
    }
    @Test func concurrentHumanButtonsDoNotSubmitConflictingChoices() async throws {
        let (service, disk, prefs) = try fixture(); let inbox = model(service, disk, prefs); await inbox.open(service.id)
        async let a: Void = inbox.decide("accept")
        async let b: Void = inbox.decide("decline")
        _ = await (a,b)
        #expect(service.decisions.count == 1 && service.approvals == 1 && inbox.selected?.state == "queued")
    }
    @Test func diskFailurePreventsSendingAndWrongReceiptKeepsTheOriginalIntent() async throws {
        let (service, _, prefs) = try fixture(); let failing = ApprovalFailingDisk(), inbox = model(service, failing, prefs)
        await inbox.open(service.id); await inbox.decide("accept")
        #expect(service.decisions.isEmpty && inbox.message != nil)
        let disk = NativeApprovalMemoryPersistence(), second = model(service, disk, prefs)
        await second.open(service.id); service.wrongReceipt = true; await second.decide("accept")
        #expect(disk.values.count == 1 && second.selected?.id == service.id)
    }
    @Test func httpSuccessWithStillPendingStateDoesNotClearOriginalDecision() async throws {
        let (service, disk, prefs) = try fixture(); service.staleReceipt = true
        let inbox = model(service, disk, prefs); await inbox.open(service.id); await inbox.decide("accept")
        #expect(disk.values.count == 1 && inbox.message != nil && inbox.selected?.state == "queued")
    }
    @Test func localRevocationOrUnsynchronizedGrantBlocksApprovalImmediately() async throws {
        let (service, disk, prefs) = try fixture(); var locallyAllowed = true
        let inbox = NativeApprovalInbox(service: service, persistence: disk, preferences: prefs, now: { self.at }, mayApprove: { _ in locallyAllowed })
        await inbox.open(service.id); let value = try #require(inbox.selected)
        #expect(inbox.canDecide(value, accept: true))
        locallyAllowed = false
        #expect(!inbox.canDecide(value, accept: true) && inbox.canDecide(value, accept: false))
        await inbox.decide("accept"); #expect(service.decisions.isEmpty && disk.values.isEmpty)
    }
    @Test func missingLocalGrantProviderFailsClosedWithoutSendingApproval() async throws {
        let (service, disk, prefs) = try fixture()
        let inbox = NativeApprovalInbox(service: service, persistence: disk, preferences: prefs, now: { self.at })
        await inbox.open(service.id); await inbox.decide("accept")
        #expect(service.decisions.isEmpty && disk.values.isEmpty)
    }
    @Test func expiredOrWrongIdentityIsNotActionableAndBadPagesAreNotCombined() async throws {
        let (service, disk, prefs) = try fixture(); let inbox = model(service, disk, prefs)
        service.expired = true; await inbox.open(service.id); await inbox.decide("accept"); #expect(service.decisions.isEmpty)
        service.expired = false; service.badPage = true; await inbox.refresh()
        #expect(!inbox.readComplete && inbox.entries.isEmpty && inbox.message != nil)
        service.badPage = false; service.wrongHash = true; await inbox.open(service.id)
        #expect(inbox.selected == nil && service.decisions.isEmpty)
    }
    @Test func incompleteBeforeValuesPreventApprovalButAllowExplicitRejection() async throws {
        let (service, disk, prefs) = try fixture(); service.missingBefore = true
        let inbox = model(service, disk, prefs); await inbox.open(service.id)
        #expect(inbox.selected?.displayError != nil)
        await inbox.decide("accept"); #expect(service.decisions.isEmpty)
        await inbox.decide("decline"); #expect(service.decisions.count == 1 && inbox.selected?.state == "declined")
    }
    @Test func notificationsRequireExplicitSeparateOptInAndAreDeduplicated() async throws {
        let (service, disk, prefs) = try fixture(); let notifier = ApprovalNotifier(), inbox = model(service, disk, prefs, notifier: notifier)
        await inbox.refresh(); #expect(notifier.authorizations == 0 && notifier.sent.isEmpty)
        notifier.allowed = false; await inbox.enableNotifications(); #expect(!inbox.notificationsEnabled)
        notifier.allowed = true; await inbox.enableNotifications(); #expect(inbox.notificationsEnabled)
        await inbox.refresh(); #expect(notifier.sent.isEmpty) // No backlog after opt-in.
        prefs.set([], forKey: "bc.nativeApprovalNotified")
        await inbox.refresh(); await inbox.refresh(); #expect(notifier.sent == [service.id])
        inbox.disableNotifications(); #expect(!inbox.notificationsEnabled)
    }
    @Test func displayPreviewCannotReachRealExecutorOrRequestNotificationPermission() async throws {
        let inbox = NativeApprovalPreview.make()
        await inbox.refresh()
        let entry = try #require(inbox.pending.first)
        await inbox.open(entry.id)
        let selected = try #require(inbox.selected)
        #expect(inbox.isDisplayTest && inbox.canDecide(selected, accept: true))
        await inbox.decide("accept")
        let result = try NativeRemoteJSON.object(try #require(inbox.selected?.result))
        #expect(result["executed"] == .bool(false) && result["operationEffect"] == .string("read_only_display"))
        #expect(inbox.retryCommandIds.isEmpty && !inbox.notificationsEnabled)
        #expect(inbox.displayTestDecision == .accept && inbox.message == "显示测试完成：已收到确认")
        await inbox.refresh(); #expect(inbox.displayTestDecision == .accept && inbox.readComplete && inbox.pending.isEmpty)
        let denied = NativeApprovalPreview.make(); await denied.refresh(); await denied.open(entry.id); await denied.decide("decline")
        #expect(denied.selected?.state == "declined" && denied.displayTestDecision == .decline)
        #expect(denied.message == "显示测试结束：已收到不执行")
    }
    #if os(macOS)
    @Test func displayCompletionFeedbackIsVisibleInNarrowAndWidePinnedFooter() async throws {
        let inbox = NativeApprovalPreview.make(); await inbox.refresh()
        await inbox.open(try #require(inbox.pending.first).id); await inbox.decide("accept")
        await inbox.refresh()
        #expect(inbox.displayTestDecision == .accept && inbox.readComplete)
        for width in [390.0, 620.0] {
            let rect = NSRect(x: 0, y: 0, width: width, height: 650)
            let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: NativeApprovalContent(model: inbox).frame(width: width, height: 650).environment(\.colorScheme, .light).background(Color.white))
            host.frame = rect; host.appearance = NSAppearance(named: .aqua); window.contentView = host; host.layoutSubtreeIfNeeded()
            for _ in 0..<20 { await Task.yield() }
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: rect)); host.cacheDisplay(in: rect, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/private/tmp/bc176-display-result-\(Int(width)).png"), options: .atomic)
            window.close()
        }
    }
    @Test func approvalLayoutNarrowAndWidePreviewWithPinnedControls() async throws {
        let (service, disk, prefs) = try fixture(); service.showUpdate = true
        let inbox = model(service, disk, prefs); await inbox.refresh(); await inbox.open(service.id)
        let entry = try #require(inbox.selected)
        #expect(inbox.canDecide(entry, accept: true) && inbox.canDecide(entry, accept: false))
        for width in [390.0, 620.0] {
            // ImageRenderer cannot capture AppKit-backed scroll containers.
            // Use an offscreen test-only host; never order it in front.
            let rect = NSRect(x: 0, y: 0, width: width, height: 800)
            let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: NativeApprovalContent(model: inbox).frame(width: width, height: 800).environment(\.colorScheme, .light).background(Color.white))
            host.frame = rect; host.appearance = NSAppearance(named: .aqua); window.contentView = host
            host.layoutSubtreeIfNeeded()
            for _ in 0..<20 { await Task.yield() }
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let scale = window.backingScaleFactor
            #expect(bitmap.pixelsWide == Int(width * scale) && bitmap.pixelsHigh == Int(800 * scale))
            try data.write(to: URL(fileURLWithPath: "/private/tmp/bc-approval-38-layout-\(Int(width)).png"), options: .atomic)
            window.close()
        }
    }
    #endif

}

@MainActor private final class ApprovalService: NativeRemoteServing {
    var nativeDeviceId: String? = "fixture-device"
    let id = "12345678-1234-4234-8234-000000001901"
    let at: Date
    var state = "awaiting_confirmation", decisions: [BridgeJSON] = []
    var approvals = 0, loseResponse = false, wrongReceipt = false, expired = false, badPage = false, wrongHash = false, missingBefore = false, showUpdate = false, staleReceipt = false
    init(at: Date) throws { self.at = at }
    func envelope(wrongId: Bool = false) throws -> BridgeJSON {
        let commandId = wrongId ? "12345678-1234-4234-8234-000000001902" : id
        let request: BridgeJSON = .object(["version": .number(1), "commandId": .string(commandId), "deviceId": .string("fixture-device"),
            "kind": .string("item"), "action": .string(missingBefore || showUpdate ? "update" : "create"), "recordId": .string("12345678-1234-4234-8234-000000001903"),
            "patch": .object(["title": .string("ISOLATED approval fixture")]),
            "expectedRevision": missingBefore || showUpdate ? .string("old-revision") : .null,
            "occurredAt": NativeRemoteJSON.timestamp(at), "expiresAt": NativeRemoteJSON.timestamp(at.addingTimeInterval(expired ? -1 : 86400)),
            "userRequest": .string("Isolated fixture; no real user task")])
        return .object(["version": .number(1), "nativeCommandId": .string(commandId), "commandId": .string(commandId), "deviceId": .string("fixture-device"),
            "requestHash": .string(wrongHash ? "wrong" : BridgePoolCodec.hash(try BridgePoolCodec.encode(request))), "request": request,
            "grantRevision": .number(1), "state": .string(state), "expiresAt": NativeRemoteJSON.timestamp(at.addingTimeInterval(expired ? -1 : 86400)),
            "serverAccepted": .bool(true), "approvedAt": ["queued", "dispatching", "applied"].contains(state) ? NativeRemoteJSON.timestamp(at) : .null,
            "display": showUpdate ? .object(["recordTitle": .string("演示事项（隔离数据）"), "deviceLabel": .string("演示 Mac"), "before": .object(["title": .string("修改前的演示标题")])]) : .null, "result": .null])
    }
    func nativeRequest(_ path: String, body: BridgeJSON) async throws -> BridgeJSON {
        await Task.yield()
        switch path {
        case "native/approvals":
            return .object(["commands": .array([try envelope()]), "through": .string(id), "nextCursor": .string(badPage ? "invalid" : id), "hasMore": .bool(badPage)])
        case "native/approval/read": return try envelope()
        case "native/approval/decide":
            decisions.append(body)
            let decision = try NativeRemoteJSON.string(NativeRemoteJSON.object(body)["decision"])
            if state == "awaiting_confirmation" { state = decision == "accept" ? "queued" : "declined"; approvals += 1 }
            if loseResponse { loseResponse = false; throw URLError(.networkConnectionLost) }
            if staleReceipt {
                var response = try NativeRemoteJSON.object(envelope()); response["state"] = .string("awaiting_confirmation"); response["approvedAt"] = .null
                return .object(response)
            }
            return try envelope(wrongId: wrongReceipt)
        default: throw URLError(.unsupportedURL)
        }
    }
}
@MainActor private final class ApprovalNotifier: NativeApprovalNotifying {
    var authorizations = 0, sent: [String] = [], allowed = true
    func authorize() async throws -> Bool { authorizations += 1; return allowed }
    func send(commandId: String) async throws { sent.append(commandId) }
}
@MainActor private final class ApprovalFailingDisk: NativeApprovalPersisting {
    func load() throws -> [NativeApprovalIntent] { [] }
    func save(_ intents: [NativeApprovalIntent]) throws { throw DataArchiveError.invalid("isolated disk failure") }
}
