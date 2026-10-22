//
//  PrivacyUsageKeysTests.swift
//  BetterCalendarTests
//
//  调用要权限的系统能力而 Info.plist 没有对应说明 = 系统直接终止 App（10-22 模拟器自测：点麦克风即闪退）。
//  App 用的是手写 Info.plist（GENERATE_INFOPLIST_FILE = NO），build setting 里的 INFOPLIST_KEY_* 不生效——这里锁住。
//

import Foundation
import Testing
@testable import BetterCalendar

@Suite struct PrivacyUsageKeysTests {
    @Test func everyPrivacyAPIWeCallHasAUsageDescription() {
        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription",
                    "NSCalendarsFullAccessUsageDescription", "NSRemindersFullAccessUsageDescription"] {
            let text = Bundle.main.object(forInfoDictionaryKey: key) as? String
            #expect(text?.isEmpty == false, "Info.plist 缺 \(key)")
        }
    }
}
