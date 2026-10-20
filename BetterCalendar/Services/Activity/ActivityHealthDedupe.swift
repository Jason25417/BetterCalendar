//
//  ActivityHealthDedupe.swift
//  BetterCalendar
//
//  W29 健康数据去重安全网（Jason：健康数据是「人」的，不是「设备」的——任何一台读到就够，但要保证干净、不重复）。
//  W28 起 iPad 不回填健康；iPhone 每次回前台回看 48 小时。已有第一道闸：记录 id 由内容决定（ActivityStableID），
//  写本机日文件按 id 去重。这里补两道（纯函数，单测直接喂记录）：
//    ① 写之前（FileActivityLog.appendNew）：与已存记录「语义重复」的健康记录不再写——
//       锻炼：键 = HealthKit 样本 UUID 派生的 id；id 不同时退到 类型+开始+结束（秒）；
//       睡眠：同一个人一段睡眠只有一段——与已存睡眠段有重叠、且不比它长的，不写（睡眠段合并后起点可能挪动，id 跟着变）。
//    ② 读的时候（FileActivityLog.events(in:)）：同 id 只留一条；锻炼按键去重；睡眠重叠的只留最长那段。
//  跨设备同理：不看 deviceId（老版本 iPad 回填过的、换机后新 iPhone 回填的，都与 iPhone 的同一段睡眠 / 同一次锻炼算重复）。
//  不删已写的行（数据只增）：旧重复只在读时折叠。智能体经桥接直接读原始日文件——①保证新数据不再进重复。
//

import Foundation

nonisolated enum ActivityHealthDedupe {
    enum Signal { case sleep, workout }

    static func signal(_ e: ActivityEvent) -> Signal? {
        guard e.kind == .other else { return nil }
        switch e.detail?["signal"] {
        case "sleep": return .sleep
        case "workout": return .workout
        default: return nil
        }
    }

    /// 健康记录覆盖的时段（睡眠：detail 的 start/end；锻炼：at → detail.end）。读不出 → nil（不参与语义去重，只按 id）。
    static func interval(_ e: ActivityEvent) -> DateInterval? {
        guard let s = signal(e) else { return nil }
        let start = s == .sleep ? (e.detail?["start"].flatMap(ActivityCodec.date) ?? e.at) : e.at
        guard let end = e.detail?["end"].flatMap(ActivityCodec.date), end >= start else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// 锻炼的退路键：类型 + 开始 + 结束（到秒）。
    static func workoutKey(_ e: ActivityEvent) -> String? {
        guard signal(e) == .workout, let i = interval(e) else { return nil }
        return "\(e.detail?["activityType"] ?? "?")|\(Int(i.start.timeIntervalSince1970))|\(Int(i.end.timeIntervalSince1970))"
    }

    /// 两段睡眠是不是同一段（有正长度的重叠）。
    static func overlaps(_ a: DateInterval, _ b: DateInterval) -> Bool {
        a.start < b.end && b.start < a.end
    }

    /// ① 写之前：incoming 里与 existing（及 incoming 里更早的）语义重复的健康记录剔掉。非健康记录原样返回（id 去重由调用方做）。
    static func filterNew(_ incoming: [ActivityEvent], existing: [ActivityEvent]) -> [ActivityEvent] {
        var workoutKeys = Set(existing.compactMap(workoutKey))
        var sleeps = existing.filter { signal($0) == .sleep }.compactMap(interval)
        var out: [ActivityEvent] = []
        for e in incoming {
            switch signal(e) {
            case .workout:
                if let k = workoutKey(e) { guard workoutKeys.insert(k).inserted else { continue } }
            case .sleep:
                if let i = interval(e) {
                    // 已有一段重叠且不比它短 → 这是同一段睡眠的另一次读法，不写；比已有的长（读到了更完整的数据）→ 写，读时留长的。
                    if sleeps.contains(where: { overlaps($0, i) && $0.duration >= i.duration }) { continue }
                    sleeps.append(i)
                }
            case nil: break
            }
            out.append(e)
        }
        return out
    }

    /// ② 读的时候：同 id 留第一条；锻炼同键留第一条；重叠的睡眠段只留最长的（一样长留更早写的）。顺序保持输入顺序。
    static func clean(_ events: [ActivityEvent]) -> [ActivityEvent] {
        var seenIds = Set<UUID>(), seenWorkouts = Set<String>()
        var unique: [ActivityEvent] = []
        for e in events where seenIds.insert(e.id).inserted {
            if let k = workoutKey(e), !seenWorkouts.insert(k).inserted { continue }
            unique.append(e)
        }
        // 睡眠：按时长从长到短挑，与已挑中的重叠就丢
        let sleepIdx = unique.indices.filter { signal(unique[$0]) == .sleep && interval(unique[$0]) != nil }
        guard sleepIdx.count > 1 else { return unique }
        let spans = Dictionary(uniqueKeysWithValues: sleepIdx.map { ($0, interval(unique[$0])!) })
        let ranked = sleepIdx.sorted { a, b in
            spans[a]!.duration != spans[b]!.duration ? spans[a]!.duration > spans[b]!.duration : a < b
        }
        var kept: [DateInterval] = [], drop = Set<Int>()
        for i in ranked {
            let iv = spans[i]!
            if kept.contains(where: { overlaps($0, iv) }) { drop.insert(i) } else { kept.append(iv) }
        }
        return unique.indices.filter { !drop.contains($0) }.map { unique[$0] }
    }
}
