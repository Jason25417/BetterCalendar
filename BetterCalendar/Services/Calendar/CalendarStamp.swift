//
//  CalendarStamp.swift
//  BetterCalendar
//
//  章 v2（P4 Q7/Q8，SPEC §19.13；设计稿 §4.3）：事件自己证明「我是谁、哪个版本、写的时候长什么样」。
//  bettercalendar://block/<UUID>?v=<版本>&h=<内容指纹>
//  - 版本 v = 计划块写入时的 syncVersion（毫秒，单调）；
//  - 指纹 h = 写入那一刻（起始分钟、结束分钟、标题）的 SHA-256 前 8 字节。
//  为什么放进事件：URL 跟着事件经 iCloud 日历同步，任何设备、任何到达顺序都能就地判断
//  「这个事件现在的内容是否还等于当初写的」——不再只靠每台设备自己的本机指纹（B6/B7/C1/C5）。
//  旧章（无 v/h）照旧能解析出块 id，第一次重画时补成 v2（零迁移）。
//  ⚠️ 真机待验：系统日历 App 编辑事件后是否原样保留带查询参数的 URL（Mac / iPhone 各验一次）。
//

import Foundation
import CryptoKit

nonisolated struct CalendarStamp: Equatable, Sendable {
    var blockID: UUID
    var version: Int64?
    var hash: String?

    static let scheme = "bettercalendar"

    /// 事件 URL。version/hash 都有才写查询参数（否则 = 旧章格式）。
    var url: URL? {
        var s = "\(Self.scheme)://block/\(blockID.uuidString)"
        if let version, let hash { s += "?v=\(version)&h=\(hash)" }
        return URL(string: s)
    }

    /// 事件 URL → 章（非本 App 的 URL → nil）。
    static func parse(_ url: URL?) -> CalendarStamp? {
        guard let url, url.scheme == scheme, url.host == "block",
              let id = UUID(uuidString: url.lastPathComponent) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let v = items.first { $0.name == "v" }?.value.flatMap(Int64.init)
        let h = items.first { $0.name == "h" }?.value
        return CalendarStamp(blockID: id, version: (v != nil && h != nil) ? v : nil, hash: (v != nil && h != nil) ? h : nil)
    }

    /// 内容指纹：起止按分钟取整（与本机指纹同一粒度：日历 App 显示/编辑的最小单位），标题原样。
    static func contentHash(start: Date, end: Date, title: String) -> String {
        let s = "\(Int(start.timeIntervalSinceReferenceDate / 60))|\(Int(end.timeIntervalSinceReferenceDate / 60))|\(title)"
        return SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension CalendarEventDraft {
    /// 带 v2 章的事件：内容的哈希是否仍等于章里的指纹（= 写入后没人动过）。旧章 → nil（判不了，退回本机指纹）。
    nonisolated var isUntouchedSinceStamped: Bool? {
        guard let h = stampHash else { return nil }
        return CalendarStamp.contentHash(start: start, end: end, title: title) == h
    }

    /// 给草稿盖 v2 章（版本 = 计划块的 syncVersion；指纹按草稿此刻的内容算）。
    nonisolated mutating func stampV2(version: Int64) {
        stampVersion = version
        stampHash = CalendarStamp.contentHash(start: start, end: end, title: title)
    }
}
