import Foundation
import UserNotifications

@MainActor final class NativeApprovalNotification: NativeApprovalNotifying {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }
    func authorize() async throws -> Bool {
        // This runs only from the separate human settings button.
        try await center.requestAuthorization(options: [.alert, .badge])
    }
    func send(commandId: String) async throws {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw DataArchiveError.invalid("审批通知未获系统授权；未发送")
        }
        let content = UNMutableNotificationContent()
        content.title = "BC 有一项改动等你确认"
        content.body = "打开核对具体内容，再决定同意或拒绝。"
        content.userInfo = ["bcApprovalCommandId": commandId]
        try await center.add(UNNotificationRequest(identifier: "bc.approval." + commandId, content: content, trigger: nil))
    }
}
