//
//  PlanChangeSource.swift
//  BetterCalendar
//
//  `ReconcileService.planChangedExternally` 的来源标记（userInfo["source"]）——B10 修复（P4.0-7，2026-10-18）。
//
//  事故：时间线协调器写 PlanStore → SwiftData 保存 → 系统发 NSPersistentStoreRemoteChange（**本机保存也会发**）
//  → DataSyncMonitor 把它转发成**不带来源**的 planChangedExternally → 协调器当成外部变更重算 → 又写 → ……
//  真机 Mac 9/16 一个多小时「外部变更：写回 1 块」10,523 次，CloudKit 一直往 iPhone 推。
//  修法：每个发出方都标来源；本机保存回声标 localStoreSave，协调器不为它重算；CloudKit 导入标 cloudImport 照常处理。
//

import Foundation

nonisolated enum PlanChangeSource {
    static let key = "source"
    /// 协调器自己写回后发（刷新界面用）。
    static let timelineCoordinator = "timelineCoordinator"
    /// 本机保存的回声（NSPersistentStoreRemoteChange 本机保存也会发）：只刷新界面，不当外部变更。
    static let localStoreSave = "localStoreSave"
    /// CloudKit 导入成功：另一台设备的改动到了——真外部变更。
    static let cloudImport = "cloudImport"
    /// 显式「重新读取」（回到前台、开发数据修改、回收站恢复）：一次性，按外部变更处理。
    static let manualRefresh = "manualRefresh"
    /// 日历手改回流（带 updatedIDs → 协调器手改冷却）。
    static let calendarReconcile = "calendarReconcile"
    // 智能体批准的挪块：ApprovedPlanMover.notificationSource（带 updatedIDs → 手改冷却）。

    /// 协调器不重算的来源：自己写的 + 本机保存回声。其余（含没标来源的旧发出方）一律按外部变更处理。
    static let ignoredByCoordinator: Set<String> = [timelineCoordinator, localStoreSave]
}

/// DataSyncMonitor 的刷新分流（纯值类型，可单测）：攒一次防抖窗口内收到的信号，刷新时决定标什么来源。
/// 只要窗口里有过一次 CloudKit 导入成功，这次刷新就算「外部变更」（防抖合并不能把导入吞掉）；
/// 只有本机保存回声 → localStoreSave（界面照常刷新，协调器不重算）。
nonisolated struct PlanChangeRouting: Sendable, Equatable {
    enum Signal: Sendable { case cloudImportSucceeded, storeRemoteChange, manualRefresh }
    private var sawImport = false
    private var sawManual = false

    mutating func note(_ signal: Signal) {
        switch signal {
        case .cloudImportSucceeded: sawImport = true
        case .manualRefresh: sawManual = true
        case .storeRemoteChange: break
        }
    }

    /// 本次刷新的来源，并清空累积。
    mutating func drain() -> String {
        defer { sawImport = false; sawManual = false }
        if sawImport { return PlanChangeSource.cloudImport }
        if sawManual { return PlanChangeSource.manualRefresh }
        return PlanChangeSource.localStoreSave
    }
}
