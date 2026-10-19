//
//  SharedRecentEdits.swift
//  BetterCalendar
//
//  W22b 跨设备手改冷却：协调器的 30 分钟手改冷却（D12「你最后的动作赢」）原来只记在本机内存里。
//  写权租约（W22）之后，自动调整只由持有写权的设备写——如果你在另一台设备上批准了智能体挪块 / 在日历里改了时间 / 点了一键撤，
//  持有者不知道这块刚被你动过，可能下一分钟就把它重新排走。
//  这里把「最近被你动过的块 → 冷却到几点」发布到 iCloud KV（与写权租约同一个存储，键 `timeline.recentEdits.v1`），
//  每台设备的协调器把它与本机冷却合并后当钉死。不写 pinnedUntil（Jason 定：只有他亲手拖动才是图钉，批准的挪块不是）。
//  不新建 CloudKit 记录类型；Dev 版与日用版的 KV 按 bundle id 天然分开。
//  写法：读 → 合并（同块取更晚的截止）→ 去掉已过期 → 最多留 maxEntries 条 → 写回。两台设备同一瞬间各写一条时，KV 后写赢可能丢掉一条，
//  丢的那条仍在发起设备的本机冷却里（与改动前相同），属可接受的退化。失败一律 DevLog 可见。
//

import Foundation

@MainActor
final class SharedRecentEdits {
    static let key = "timeline.recentEdits.v1"
    /// 最多保留几条（冷却 30 分钟，正常远用不到；防异常膨胀，KV 单键上限 1MB）。
    static let maxEntries = 200

    private let store: any WriteLeaseStoring
    private let log: @MainActor (DevLog.Level, String) -> Void
    private var syncFailureLogged = false
    private var decodeFailureLogged = false

    init(store: any WriteLeaseStoring,
         log: @escaping @MainActor (DevLog.Level, String) -> Void = { level, msg in
             switch level {
             case .info: DevLog.shared.info("手改冷却", msg)
             case .warning: DevLog.shared.warn("手改冷却", msg)
             case .error: DevLog.shared.error("手改冷却", msg)
             }
         }) {
        self.store = store
        self.log = log
    }

    /// 发布：这些块冷却到 until（与已有条目合并，同块取更晚）。
    func publish(ids: [UUID], until: Date, now: Date) {
        guard !ids.isEmpty else { return }
        var map = read(now: now)
        for id in ids { map[id] = max(map[id] ?? until, until) }
        let kept = map.sorted { $0.value > $1.value }.prefix(Self.maxEntries)
        let raw = Dictionary(uniqueKeysWithValues: kept.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) })
        do {
            let data = try JSONEncoder().encode(raw)
            if store.save(data) {
                syncFailureLogged = false
            } else if !syncFailureLogged {   // 只记第一次，恢复后再失败会再记
                syncFailureLogged = true
                log(.warning, "手改冷却没能同步到 iCloud（KV synchronize 失败）——这次只在本机生效，下次再试")
            }
        } catch {
            log(.warning, "手改冷却编码失败，这次只在本机生效：\(error.localizedDescription)")
        }
    }

    /// 读取仍在冷却中的块（已过期的丢掉）。
    func active(now: Date) -> [UUID: Date] { read(now: now) }

    private func read(now: Date) -> [UUID: Date] {
        guard let data = store.load() else { return [:] }
        guard let raw = try? JSONDecoder().decode([String: Double].self, from: data) else {
            if !decodeFailureLogged {   // 每轮重算都会读，只记第一次
                decodeFailureLogged = true
                log(.warning, "iCloud 里的手改冷却记录读不懂，先只用本机冷却（下次写入时会覆盖）")
            }
            return [:]
        }
        decodeFailureLogged = false
        var out: [UUID: Date] = [:]
        for (k, v) in raw {
            guard let id = UUID(uuidString: k) else { continue }
            let until = Date(timeIntervalSince1970: v)
            if until > now { out[id] = until }
        }
        return out
    }
}
