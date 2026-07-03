//
//  JournalSettings.swift
//  BetterCalendar
//
//  日记设置（R5）：隐私锁开关（UserDefaults，跟其它设置同模式）。
//  开着 → 进日记页要 Face ID / Touch ID / 密码解锁；退后台自动重新上锁。
//

import Foundation

enum JournalSettings {
    private static let d = UserDefaults.standard

    static var privacyLock: Bool {
        get { d.bool(forKey: "journal.privacyLock") }
        set { d.set(newValue, forKey: "journal.privacyLock") }
    }
}
