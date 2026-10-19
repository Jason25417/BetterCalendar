//
//  ActivityPhoneSink.swift
//  BetterCalendar
//
//  W13：「记一条」的统一入口（快捷指令、iPhone / iPad 运动/健康回填、网络变化都走这里）：
//    先写本机日文件 → iOS 设备再进待上传队列并尽力传 iCloud（传不上留在队列里，下次再传）。
//  W28：这里是给每条记录盖「设备类别」章（iphone / ipad / mac）的唯一位置——调用方不用各自判断。
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
    /// W28：本机设备类别；记下时给没有类别的记录补上。nil = 不补（测试按需显式传）。
    nonisolated let deviceKind: ActivityDeviceKind?

    init(log: FileActivityLog, outbox: ActivityOutbox?, transport: (any ActivityCloudTransport)?, deviceKind: ActivityDeviceKind? = nil) {
        self.log = log; self.outbox = outbox; self.transport = transport; self.deviceKind = deviceKind
    }

    /// 生产单例（测试绝不碰：测试各自构造内存版）。
    static let shared: ActivityPhoneSink = {
        let log = FileActivityLog(root: FileActivityLog.defaultRoot)
        #if os(iOS)
        return ActivityPhoneSink(log: log, outbox: ActivityOutbox(url: ActivityOutbox.defaultURL), transport: CloudKitActivityStore(),
                                 deviceKind: .current)
        #else
        return ActivityPhoneSink(log: log, outbox: nil, transport: nil, deviceKind: .current)
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
        let stamped = deviceKind.map { kind in events.map { e in var e = e; if e.deviceKind == nil { e.deviceKind = kind.rawValue }; return e } } ?? events
        let fresh = try await log.appendNew(stamped)
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

/// 快捷指令「记录 App 打开 / 关闭」的业务逻辑（Intent 只是壳，这里可单测）。打开 / 关闭的判断见 PhoneAppSession。
/// 状态读 → 改 → 存在主线程上一气呵成（两个动作几乎同时触发也不会互相覆盖），之后才异步写日志 / 上传。
enum ActivityShortcutRecorder {
    enum Result: Equatable { case recorded([ActivityEvent], ActivityPhoneSink.Outcome), notRecording }

    /// 「记录 App 打开」：appName = 自动化里「获取当前 App」的结果。
    static func recordOpened(appName: String?, at: Date, deviceId: String, platform: String, sink: ActivityPhoneSink,
                             defaults: UserDefaults = .standard, extra: [String: String] = [:]) async throws -> Result {
        guard ActivitySettings.isRecording(at: at, defaults) else { return .notRecording }
        var session = PhoneAppSession.load(defaults)
        let events = session.opened(appName, at: at, .init(deviceId: deviceId, platform: platform, extra: extra))
        session.save(defaults)
        return .recorded(events, try await sink.record(events))
    }

    /// 「记录 App 关闭」：frontApp = 关闭触发后等 2 秒再「获取当前 App」的结果（回到主屏幕为空）。
    static func recordClosed(frontApp: String?, at: Date, deviceId: String, platform: String, sink: ActivityPhoneSink,
                             defaults: UserDefaults = .standard, extra: [String: String] = [:]) async throws -> Result {
        guard ActivitySettings.isRecording(at: at, defaults) else { return .notRecording }
        var session = PhoneAppSession.load(defaults)
        let events = session.closed(front: frontApp, at: at, .init(deviceId: deviceId, platform: platform, extra: extra))
        session.save(defaults)
        return .recorded(events, try await sink.record(events))
    }

    static var platform: String {
        #if os(iOS)
        "iOS"
        #else
        "macOS"
        #endif
    }

    /// iPhone / iPad：顺手记下电量与是否在充电（不需要权限；读不到就不写）。
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
