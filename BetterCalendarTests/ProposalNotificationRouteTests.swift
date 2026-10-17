import Foundation
import Testing
import UserNotifications
@testable import BetterCalendar

/// SPEC §19 B1/B5：通知点击解析——本机通知与 iCloud 代发推送都能找到同一份提案；点通知本身绝不当作批准。
@MainActor @Suite struct ProposalNotificationRouteTests {
    let id = UUID()

    @Test func localNotificationActionsMapToDecisionsAndDefaultTapOnlyOpens() {
        let info: [AnyHashable: Any] = [LocalProposalNotifier.userInfoKey: id.uuidString]
        #expect(LocalProposalNotifier.route(userInfo: info, actionIdentifier: LocalProposalNotifier.approveAction)?.decision == .approve)
        #expect(LocalProposalNotifier.route(userInfo: info, actionIdentifier: LocalProposalNotifier.declineAction)?.decision == .decline)
        let tap = LocalProposalNotifier.route(userInfo: info, actionIdentifier: UNNotificationDefaultActionIdentifier)
        #expect(tap?.id == id && tap?.decision == nil)
        #expect(LocalProposalNotifier.route(userInfo: info, actionIdentifier: "something.else") == nil)
        #expect(!LocalProposalNotifier.isRemoteAlert(info))
    }

    @Test func requestCarriesCategoryBodyAndStableIdentifier() {
        let at = Date(timeIntervalSince1970: 1_792_000_000)
        let p = Proposal(id: id, createdAt: at, expiresAt: at.addingTimeInterval(3600), origin: .agent, originLabel: "BetterCalendar 智能体",
                         originDeviceId: "mac", parentId: nil, targetDeviceId: nil, title: "挪动笔记",
                         changes: [ProposalChange(field: "开始", before: "14:00", after: "15:00")], reason: "午饭晚了",
                         action: .experimentNoop(note: "x"), experiment: true, state: .pending)
        let r = LocalProposalNotifier.request(for: p)
        #expect(r.identifier == "bc.proposal." + id.uuidString && r.content.categoryIdentifier == "BC_PROPOSAL")
        #expect(r.content.title == "挪动笔记" && r.content.body.contains("14:00 → 15:00") && r.content.subtitle.hasPrefix("测试"))
    }

    @Test func iCloudAlertPushPayloadResolvesToProposal() {
        let info: [AnyHashable: Any] = [
            "aps": ["alert": ["title-loc-key": "BC_PROPOSAL_PUSH_TITLE", "loc-key": "BC_PROPOSAL_PUSH_BODY"], "category": "BC_PROPOSAL"],
            "ck": ["ce": 2, "cid": "iCloud.com.jason.BetterCalendar", "nid": UUID().uuidString,
                   "qry": ["dbs": 1, "fo": 1, "rid": id.uuidString, "sid": CloudKitProposalStore.alertSubscriptionID,
                           "zid": "BCApprovals", "zoid": "__defaultOwner__"]]
        ]
        #expect(CloudKitProposalStore.isProposalPush(info))
        #expect(LocalProposalNotifier.isRemoteAlert(info))
        #expect(LocalProposalNotifier.route(userInfo: info, actionIdentifier: LocalProposalNotifier.approveAction)?.id == id)
    }
}
