import Foundation
import Testing
@testable import BetterCalendar

struct StateBridgeScheduleReaderTests {
    @Test func failedReminderReadDoesNotBecomeEmptySuccess() {
        let empty = BridgeScheduleProjection.bounded([], totalCount: 0, limit: 100)
        #expect(empty != BridgeScheduleProjection.unreadableReminders)
        #expect(empty == .object(["availability": .string("available"), "items": .array([]),
                                 "truncated": .bool(false), "omittedItems": .number(0)]))
    }

    @Test func manyUnicodeItemsStayWithinObservationBudgetWithExplicitOmissions() throws {
        let item = BridgeJSON.object(["title": .string(String(repeating: "长标题🌲", count: 200)), "id": .string("event")])
        let result = BridgeScheduleProjection.bounded(Array(repeating: item, count: 120), totalCount: 220, limit: 120)
        #expect(try JSONEncoder().encode(result).count < 44 * 1024)
        guard case .object(let body) = result, case .array(let items) = body["items"] else { Issue.record("Missing bounded items"); return }
        #expect(!items.isEmpty && items.count < 120)
        #expect(body["availability"] == .string("partial"))
        #expect(body["omittedItems"] == .number(Double(220 - items.count)))
    }

    @Test func oversizedSingleEntryKeepsFailureVisibleRatherThanClaimingNoItems() {
        let item = BridgeJSON.string(String(repeating: "x", count: 50 * 1024))
        #expect(BridgeScheduleProjection.bounded([item], totalCount: 1, limit: 1) ==
                .object(["availability": .string("partial"), "items": .array([]), "truncated": .bool(true), "omittedItems": .number(1)]))
    }
}
