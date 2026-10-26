//
//  W46DecisionsTests.swift
//  BetterCalendarTests
//
//  0.77（Jason 2026-10-26 拍板）：BetterCalendar 自家的块删除可自动通过、他个人日历的删除出提案卡（不直接拒）；
//  调的数值冲突也能发出去由智能体接着调；每天一次投放建议。
//

import Foundation
import Testing
@testable import BetterCalendar

@MainActor @Suite struct W46DecisionsTests {
    func value(_ a: ProposalAction) -> Proposal {
        Proposal(id: UUID(), createdAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 3600), origin: .agent,
                 originLabel: "x", originDeviceId: "mac", parentId: nil, targetDeviceId: nil, title: "t", changes: [], reason: "r",
                 action: a, experiment: false, state: .pending, decidedAt: nil, decidedByDeviceId: nil, appliedAt: nil, resultNote: nil)
    }

    @Test func deletingOurOwnBlockCanAutoPassButYourEventsNever() {
        #expect(PreauthPolicy.lowRiskReason(value(.blockDelete(id: UUID(), expectedRevision: nil))) == nil)
        var pinned = value(.blockDelete(id: UUID(), expectedRevision: nil)); pinned.autoPassBlocker = "「写论文」是你亲手放的位置（图钉）"
        #expect(PreauthPolicy.evaluate(pinned, rules: [], lowRiskAutoPass: true).route == .ask)
        let ref = YourEventRef(externalID: "e", occurrenceStart: Date(timeIntervalSince1970: 100))
        #expect(PreauthPolicy.lowRiskReason(value(.yourEventDelete(ref: ref, expectedRevision: nil, span: nil))) != nil)
        #expect(PreauthPolicy.lowRiskReason(value(.itemDelete(id: UUID(), expectedRevision: nil))) != nil, "删你的事项仍要你批")
    }

    @Test func misplacedEscalationIsLiftedOutOfTheAction() throws {
        let file = try BuiltinAgentToolbox.proposalFile(["title": "删 5635", "reason": "他让我删",
            "action": ["kind": "yourEventDelete", "eventId": "x", "occurrenceStart": "2026-10-26T09:10:00-04:00", "escalation": "他要求删"]],
            id: UUID(), eventId: nil)
        #expect(file["escalation"] as? String == "他要求删")
        #expect((file["action"] as? [String: Any])?["escalation"] == nil)
    }

    @Test func sendingAConflictingTunedValueSaysToAdjustTheRest() {
        let p = ProposalParameter(id: "len", label: "时长", kind: .duration, bind: .duration, defaultValue: .number(60),
                                  min: .number(15), max: .number(240), step: 15)
        let text = ProposalParameterRules.sendAnywayText([p], ["len": .number(150)], reason: "和「组会」(17:00–18:00) 重叠", optionLabel: nil)
        #expect(text.hasPrefix("就按我调的来") && text.contains("时长") && text.contains("组会") && text.contains("调整别的安排"))
    }

    @Test func planSuggestFiresOncePerDayAcrossDevices() {
        let d = UserDefaults(suiteName: "bc-w46-" + UUID().uuidString)!
        let cal = Calendar.current
        let day = cal.date(from: DateComponents(year: 2026, month: 10, day: 26))!
        func t(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day)! }
        #expect(PlanSuggestSettings.dueDayKey(d, now: t(10, 0)) == nil, "还没到 10:30")
        let key = PlanSuggestSettings.dueDayKey(d, now: t(10, 40))
        #expect(key != nil)
        d.set(key, forKey: PlanSuggestSettings.sentDayKey)   // 另一台（经 iCloud）已经发过
        #expect(PlanSuggestSettings.dueDayKey(d, now: t(10, 45)) == nil)
        #expect(PlanSuggestSettings.dueDayKey(UserDefaults(suiteName: "bc-w46b-" + UUID().uuidString)!, now: t(14, 0)) == nil, "过了 3 小时不补")
    }
}
