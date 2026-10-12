import Foundation
import Testing
@testable import BetterCalendar

struct StateBridgeBrowserReaderTests {
    @Test func credentialsQueriesAndFragmentsNeverReachQueue() {
        let result = BridgeBrowserProjection.readable(url: "https://name:secret@example.com/study?token=private#private", title: "学习")
        guard case .object(let body) = result else { Issue.record("missing body"); return }
        #expect(body["url"] == .string("https://example.com/study"))
        #expect(body["availability"] == .string("available"))
    }
    @Test func permissionFailureDoesNotClaimBrowserIsEmpty() {
        let denied = BridgeBrowserProjection.failure(code: -1743)
        let unavailable = BridgeBrowserProjection.failure(code: -600)
        #expect(denied != unavailable && denied != BridgeBrowserProjection.notFrontmost())
        guard case .object(let body) = denied else { Issue.record("missing body"); return }
        #expect(body["availability"] == .string("not-authorized"))
        #expect(body["reason"] == .string("automation-permission-denied"))
    }
    @Test func readTimeoutRemainsAnError() {
        guard case .object(let body) = BridgeBrowserProjection.failure(code: -1712) else { Issue.record("missing body"); return }
        #expect(body["availability"] == .string("read-unavailable"))
        #expect(body["reason"] == .string("browser-read-timeout"))
    }
    @Test func noWindowAndInternalPageAreExplicitReadableEmptyStates() {
        guard case .object(let empty) = BridgeBrowserProjection.readable(url: nil, title: nil, noWindows: true),
              case .object(let internalPage) = BridgeBrowserProjection.readable(url: "edge://settings/passwords", title: "private") else { Issue.record("missing body"); return }
        #expect(empty["items"] == .array([]) && empty["availability"] == .string("available"))
        #expect(internalPage["items"] == .array([]) && internalPage["url"] == nil && internalPage["title"] == nil)
    }
    @Test func invalidAndOversizedURLsAreNotReportedAsSuccess() {
        guard case .object(let invalid) = BridgeBrowserProjection.readable(url: "invalid", title: "x"),
              case .object(let large) = BridgeBrowserProjection.readable(url: "https://example.com/" + String(repeating: "x", count: 4096), title: "x") else { Issue.record("missing body"); return }
        #expect(invalid["availability"] == .string("read-unavailable"))
        #expect(large["availability"] == .string("read-unavailable"))
    }
    @Test func scriptsUseKnownBundleIDsAndTitlesStayBounded() {
        #expect(BridgeBrowserProjection.supportedBundles.contains("com.microsoft.edgemac"))
        #expect(!BridgeBrowserProjection.supportedBundles.contains("bad\" application"))
        guard case .object(let body) = BridgeBrowserProjection.readable(url: "https://example.com", title: String(repeating: "学习🌲", count: 1000)) else { Issue.record("missing body"); return }
        #expect(body["title"] == .string(String(String(repeating: "学习🌲", count: 1000).prefix(300))))
    }
}
