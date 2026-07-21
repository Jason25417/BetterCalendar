//
//  CalendarSettings.swift
//  BetterCalendar
//
//  日历后端开关（假日历预览 / 真 Apple 日历）。运行时热切换：每次写读都读它。
//

import Foundation

enum CalendarSettings {
    private static let defaults = UserDefaults.standard

    static var backend: CalendarBackend {
        get {
            // 单测/预览 host 恒 fake：test host 无 GUI，走真 EventKit 会卡在日历权限请求处挂死 runner
            //（2026-07-21 实锤：EKEventStore 在无头 host 阻塞 → hung before connection）。检测见 [[TestHost]]。
            if TestHost.isActive { return .fake }
            // 生产**恒 eventKit、无视任何历史存储值**（2026-07-21 根治，Jason 实锤报「日程又写假日历」）：
            // 后端选择 2026-07-07 已退役、一律写真日历。真 bug 根因 = 老设备 UserDefaults 存过 "calendar.backend"="fake"
            //（当年开关还在时手动切过 / 老版本写入）——getter 原本「存储值 ?? 默认」使存储的 fake 优先级高于默认、
            // 也压过 AppContainer.init 的强制 set（初始化时序），于是日程静默写进假日历、系统日历里空空如也。
            // 退役 API 生产不该再切换 → 直接返回 eventKit，断绝 fake 泄漏到写路由的一切路径（改默认值救不了已存 fake 的设备）。
            return .eventKit
        }
        set { defaults.set(newValue.rawValue, forKey: "calendar.backend") }   // 保留：仅 test host 里测试显式注入 fake 用
    }
}
