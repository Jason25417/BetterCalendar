//
//  DeviceLog.swift
//  BetterCalendar
//
//  跨端日志（0.14，Jason 提出）：每设备每逻辑日一条记录，DevLog 条目节流追加到 text，
//  随 CloudKit 同步 → 在 Mac 上能看到 iOS 内测版的日志（LogSyncService 会把全部设备
//  日志 dump 成容器内纯文本，Claude 可直接命令行读）。保留 7 天，旧的自动清。
//  CloudKit 约束：默认值 ✓、无 unique ✓（同键并发重复无害，读取端按 modifiedAt 合并显示）。
//

import Foundation
import SwiftData

@Model
final class DeviceLog {
    var deviceID: String = ""      // 每安装稳定 UUID
    var deviceName: String = ""    // 如 "Jason 的 MacBook Air" / "iPhone"
    var dayKey: String = ""        // 逻辑日 yyyy-MM-dd
    var text: String = ""          // 追加式日志文本
    var modifiedAt: Date = Date.now

    init(deviceID: String, deviceName: String, dayKey: String,
         text: String = "", modifiedAt: Date = .now) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.dayKey = dayKey
        self.text = text
        self.modifiedAt = modifiedAt
    }
}
