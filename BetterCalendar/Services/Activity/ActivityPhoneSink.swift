//
//  ActivityPhoneSink.swift
//  BetterCalendar
//
//  W13：「记一条」的统一入口（快捷指令、iPhone 运动/健康回填、iPhone 网络变化都走这里）：
//    先写本机日文件 → iPhone 再进待上传队列并尽力传 iCloud（传不上留在队列里，下次再传）。
//  Mac 上同一入口只写本机（Mac 的记录本来就在本机，智能体就在这台 Mac 上）。
//  不依赖 AppContainer：快捷指令可能在 App 没开时把进程在后台拉起来，只做这一件事就走。
//

import CryptoKit
import Foundation
#if os(iOS)
import UIKit
#endif

actor ActivityPhoneSink {
    nonisolated let log: FileActivityLog
    nonisolated let outbox: ActivityOutbox?
    nonisolated let transport: (any ActivityCloudTransport)?

    init(log: FileActivityLog, outbox: ActivityOutbox?, transport: (any ActivityCloudTransport)?) {
        self.log = log; self.outbox = outbox; self.transport = transport
    }

    /// 生产单例（测试绝不碰：测试各自构造内存版）。
    static let shared: ActivityPhoneSink = {
        let log = FileActivityLog(root: FileActivityLog.defaultRoot)
        #if os(iOS)
        return ActivityPhoneSink(log: log, outbox: ActivityOutbox(url: ActivityOutbox.defaultURL), transport: CloudKitActivityStore())
        #else
        return ActivityPhoneSink(log: log, outbox: nil, transport: nil)
        #endif
    }()

    nonisolated struct Outcome: Equatable, Sendable {
        var written = 0
        var uploaded = 0
        var pendingUpload = 0
        var uploadError: String?
    }

    /// 记下（按 id 去重：回填可重放）并尽力上传。写本机失败直接抛出（调用方要让失败可见）。
    func record(_ events: [ActivityEvent]) async throws -> Outcome {
        let fresh = try await log.appendNew(events)
        var o = Outcome(written: fresh.count)
        if let outbox, !fresh.isEmpty { try await outbox.enqueue(fresh) }
        let f = await flush()
        o.uploaded = f.uploaded; o.pendingUpload = f.pendingUpload; o.uploadError = f.uploadError
        return o
    }

    /// 把队列里的尽量传完（一次最多几轮，避免后台时间用完）。
    func flush() async -> Outcome {
        guard let outbox, let transport else { return Outcome() }
        var o = Outcome()
        for _ in 0..<5 {
            let r = await outbox.flush(transport)
            o.uploaded += r.sent
            if let e = r.error { o.uploadError = e.localizedDescription; break }
            if r.sent == 0 { break }
        }
        o.pendingUpload = await outbox.count
        return o
    }
}

/// 由内容确定的 UUID（回填同一段睡眠 / 同一次运动状态变化，重复读到也是同一个 id → 去重）。
nonisolated enum ActivityStableID {
    static func make(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // 版本 5 形式（名字派生）
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// 快捷指令「记录 App 打开/关闭」的业务逻辑（Intent 只是壳，这里可单测）。
enum ActivityShortcutRecorder {
    enum Result: Equatable { case recorded(ActivityPhoneSink.Outcome), notRecording }

    static func event(opened: Bool, appName: String?, at: Date, deviceId: String, platform: String,
                      extra: [String: String] = [:]) -> ActivityEvent {
        let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        var detail = extra
        if name?.isEmpty != false { detail["appUnknown"] = "true" }   // 「所有 App」一条自动化：系统不告诉是哪个 App
        return ActivityEvent(at: at, kind: opened ? .appOpened : .appClosed, source: .shortcut, deviceId: deviceId, platform: platform,
                             appName: (name?.isEmpty == false) ? String(name!.prefix(80)) : nil, detail: detail.isEmpty ? nil : detail)
    }

    static func record(opened: Bool, appName: String?, at: Date, deviceId: String, platform: String,
                       sink: ActivityPhoneSink, defaults: UserDefaults = .standard, extra: [String: String] = [:]) async throws -> Result {
        guard ActivitySettings.isRecording(at: at, defaults) else { return .notRecording }
        let e = event(opened: opened, appName: appName, at: at, deviceId: deviceId, platform: platform, extra: extra)
        return .recorded(try await sink.record([e]))
    }

    static var platform: String {
        #if os(iOS)
        "iOS"
        #else
        "macOS"
        #endif
    }

    /// iPhone：顺手记下电量与是否在充电（不需要权限；读不到就不写）。
    static func deviceExtras() -> [String: String] {
        #if os(iOS)
        let d = UIDevice.current
        d.isBatteryMonitoringEnabled = true
        var o: [String: String] = [:]
        if d.batteryLevel >= 0 { o["batteryPercent"] = String(Int((d.batteryLevel * 100).rounded())) }
        switch d.batteryState {
        case .charging: o["battery"] = "charging"
        case .full: o["battery"] = "full"
        case .unplugged: o["battery"] = "unplugged"
        default: break
        }
        return o
        #else
        return [:]
        #endif
    }
}
