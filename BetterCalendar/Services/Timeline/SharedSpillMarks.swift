//
//  SharedSpillMarks.swift
//  BetterCalendar
//
//  W27 溢出结算的跨设备「已结算」标记：某逻辑日的溢出硬执行（收工盖章 / 启动补结算）原来只在本机 UserDefaults 里记「做过了」。
//  两台设备时：你在 Mac 上收工盖章（溢出收进待办区），第二天 iPhone 启动补结算那一天——如果 Mac 的删除还在 CloudKit 路上，
//  iPhone 看到的候选还在，会再收一遍 → 待办区里同一件出现两份。
//  这里把「哪天已经结算过」发布到 iCloud KV（与写权租约同一个存储，键 `timeline.spillsSettled.v1`），结算前先看一眼；
//  补结算本身仍受写权租约管（W22），这是第二道线。KV 也没送到的极端情况见 SPEC §19.14 W27 遗留。
//  不新建 CloudKit 记录类型；失败一律 DevLog 可见。
//

import Foundation

@MainActor
final class SharedSpillMarks {
    static let key = "timeline.spillsSettled.v1"
    /// 只留最近这么多天（补结算最多回看 7 天）。
    static let keepDays = 14

    private let store: any WriteLeaseStoring
    private let log: @MainActor (DevLog.Level, String) -> Void
    private var syncFailureLogged = false

    init(store: any WriteLeaseStoring,
         log: @escaping @MainActor (DevLog.Level, String) -> Void = { level, msg in
             switch level {
             case .info: DevLog.shared.info("溢出", msg)
             case .warning: DevLog.shared.warn("溢出", msg)
             case .error: DevLog.shared.error("溢出", msg)
             }
         }) {
        self.store = store
        self.log = log
    }

    /// 这一天是否已由某台设备结算过；是 → 返回那台设备的名字。
    func settledBy(day: Date) -> String? { read()[DayContext.dayKey(day)] }

    /// 记下：这一天已结算（by = 本机名字）。
    func markSettled(day: Date, by device: String) {
        var map = read()
        map[DayContext.dayKey(day)] = device
        // dayKey = yyyy-MM-dd：字典序即时间序，留最近 keepDays 天
        let kept = Dictionary(uniqueKeysWithValues: map.sorted { $0.key > $1.key }.prefix(Self.keepDays).map { ($0.key, $0.value) })
        do {
            let data = try JSONEncoder().encode(kept)
            if store.save(data) {
                syncFailureLogged = false
            } else if !syncFailureLogged {
                syncFailureLogged = true
                log(.warning, "溢出「已结算」标记没能同步到 iCloud（KV synchronize 失败）——另一台设备暂时看不到，下次再试")
            }
        } catch {
            log(.warning, "溢出「已结算」标记编码失败：\(error.localizedDescription)")
        }
    }

    private func read() -> [String: String] {
        guard let data = store.load() else { return [:] }
        guard let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            log(.warning, "iCloud 里的溢出「已结算」标记读不懂，先只看本机记录（下次写入时会覆盖）")
            return [:]
        }
        return map
    }
}
