//
//  SharedTimerRecordStore.swift
//  BetterCalendar
//
//  W5：共享计时会话的版本化存储协议（生产=CloudKit，测试=内存）。
//  save 只在「服务器版本与最近一次读取一致」时成功，冲突时附服务器最新版本（同 ProposalRecordStore）。
//

import Foundation

nonisolated enum SharedTimerSaveResult: Sendable {
    case saved(SharedTimerSession)
    /// 自上次读取后服务器版本已变（或新建时同 ID 已存在）；附服务器上的最新版本。
    case conflict(SharedTimerSession)
}

nonisolated protocol SharedTimerRecordStore: Sendable {
    /// 全部会话（含已结束；增量拉取并刷新已知版本）。损坏记录跳过并可见报错。
    func allSessions() async throws -> [SharedTimerSession]
    /// 从服务器读这一条的最新版本（并记住版本，供下一次 save 做条件保存）；不存在为 nil。
    func latest(_ id: String) async throws -> SharedTimerSession?
    /// 条件保存：isNew=true 要求服务器上不存在；否则要求服务器版本等于最近一次 latest 读到的版本。
    func save(_ session: SharedTimerSession, isNew: Bool) async throws -> SharedTimerSaveResult
}

/// 内存版「云」（测试用）：多个 MemorySharedTimerStore（=多台设备）共享同一份行。
/// 可注入读写之间另一端抢先写入、断网、回包丢失。
actor MemorySharedTimerCloud {
    fileprivate var rows: [String: SharedTimerSession] = [:]
    fileprivate var beforeSave: (@Sendable () async -> Void)?
    fileprivate var failNext: Error?
    fileprivate var loseReplyNext = false
    private(set) var saveCount = 0

    func setBeforeSave(_ hook: (@Sendable () async -> Void)?) { beforeSave = hook }
    /// 下一次任何调用抛出该错误（模拟断网/限流）。
    func failNextCall(_ error: Error) { failNext = error }
    /// 下一次保存真实落库，但回包丢失（抛超时）。
    func loseNextReply() { loseReplyNext = true }
    func session(_ id: String) -> SharedTimerSession? { rows[id] }
    /// 绕过条件保存直接写（模拟另一台设备）。
    func forceWrite(_ session: SharedTimerSession) { rows[session.id] = session }

    fileprivate func consumeFailure() throws {
        if let error = failNext { failNext = nil; throw error }
    }
    fileprivate func takeHook() -> (@Sendable () async -> Void)? { defer { beforeSave = nil }; return beforeSave }
    fileprivate func commit(_ session: SharedTimerSession, isNew: Bool, seen: Int?) throws -> SharedTimerSaveResult {
        let current = rows[session.id]
        if isNew {
            if let current { return .conflict(current) }
        } else {
            guard let current else { throw SharedTimerRejection(code: 404, message: "找不到计时记录") }
            guard seen == current.revision else { return .conflict(current) }
        }
        rows[session.id] = session
        saveCount += 1
        if loseReplyNext { loseReplyNext = false; throw URLError(.timedOut) }
        return .saved(session)
    }
}

/// 内存版存储的「一台设备」视角：自己记住读到的版本（条件保存按本设备读到的版本判断）。
actor MemorySharedTimerStore: SharedTimerRecordStore {
    let cloud: MemorySharedTimerCloud
    private var lastSeen: [String: Int] = [:]

    init(cloud: MemorySharedTimerCloud = MemorySharedTimerCloud()) { self.cloud = cloud }

    func allSessions() async throws -> [SharedTimerSession] {
        try await cloud.consumeFailure()
        let rows = await cloud.rows
        for (id, row) in rows { lastSeen[id] = row.revision }
        return Array(rows.values)
    }

    func latest(_ id: String) async throws -> SharedTimerSession? {
        try await cloud.consumeFailure()
        let row = await cloud.rows[id]
        lastSeen[id] = row?.revision
        return row
    }

    func save(_ session: SharedTimerSession, isNew: Bool) async throws -> SharedTimerSaveResult {
        try await cloud.consumeFailure()
        if let hook = await cloud.takeHook() { await hook() }
        do {
            let result = try await cloud.commit(session, isNew: isNew, seen: lastSeen[session.id])
            switch result {
            case let .saved(s): lastSeen[s.id] = s.revision
            case let .conflict(s): lastSeen[s.id] = s.revision
            }
            return result
        } catch let error as URLError {
            lastSeen[session.id] = session.revision   // 已落库、只是回包丢失
            throw error
        }
    }
}
