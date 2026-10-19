//
//  PhoneActivitySources.swift
//  BetterCalendar
//
//  W13（iPhone / iPad，便宜的附加来源）：每次 App 回到前台时回填——
//    - 运动状态（CoreMotion 运动活动历史，系统保留约 7 天）：步行 / 跑步 / 骑行 / 乘车 / 静止，只记状态变化；
//    - 健康：睡眠段（把「睡着」的各阶段样本合并成一段）、锻炼（HealthKit）。
//  权限：Info.plist 早已有 NSMotionUsageDescription / NSHealthShareUsageDescription，iOS entitlement 早已有 HealthKit，
//  不需要改工程配置。首次回填时系统弹授权（App 在前台时）；拒绝 = 状态行显示「没有权限」。
//  去重：id 由内容决定（ActivityStableID），每次都回看最近 48 小时，重复读到不会重复记。
//  转换逻辑是纯函数（单测直接喂样本），系统读取只在 iOS 编译。
//

import Foundation

nonisolated enum PhoneActivityTransforms {
    nonisolated struct MotionSample: Sendable { var start: Date; var activity: String; var confidence: String }
    nonisolated struct SleepSample: Sendable { var start: Date; var end: Date }

    /// 运动样本 → 只保留状态变化的那些。
    static func motionEvents(_ samples: [MotionSample], deviceId: String) -> [ActivityEvent] {
        var out: [ActivityEvent] = [], last: String?
        for s in samples.sorted(by: { $0.start < $1.start }) where s.activity != last {
            last = s.activity
            out.append(ActivityEvent(id: ActivityStableID.make("motion-\(Int(s.start.timeIntervalSince1970 * 1000))-\(s.activity)"),
                                     at: s.start, kind: .other, source: .history, deviceId: deviceId, platform: "iOS",
                                     detail: ["signal": "motion", "activity": s.activity, "confidence": s.confidence]))
            if out.count >= 2000 { break }   // 稳定性边界：一次回填最多 2000 条
        }
        return out
    }

    /// 睡着的样本 → 合并成段（间隔 < 30 分钟算同一段），只收已经结束 ≥ 1 小时的段（还在睡 / 刚醒的下次再收，避免段被切开）。
    static func sleepEvents(_ samples: [SleepSample], now: Date, deviceId: String) -> [ActivityEvent] {
        var sessions: [(start: Date, end: Date)] = []
        for s in samples.sorted(by: { $0.start < $1.start }) {
            if let last = sessions.last, s.start.timeIntervalSince(last.end) < 1800 {
                sessions[sessions.count - 1].end = max(last.end, s.end)
            } else { sessions.append((s.start, s.end)) }
        }
        return sessions.filter { now.timeIntervalSince($0.end) >= 3600 && $0.end > $0.start }.map { s in
            ActivityEvent(id: ActivityStableID.make("sleep-\(Int(s.start.timeIntervalSince1970))"), at: s.start, kind: .other,
                          source: .history, deviceId: deviceId, platform: "iOS",
                          detail: ["signal": "sleep", "start": ActivityCodec.iso(s.start), "end": ActivityCodec.iso(s.end),
                                   "minutes": String(Int(s.end.timeIntervalSince(s.start) / 60))])
        }
    }
}

#if os(iOS)
import CoreMotion
import HealthKit

@MainActor final class PhoneActivitySources {
    private let motion = CMMotionActivityManager()
    private let health = HKHealthStore()
    private let sink: ActivityPhoneSink
    private let status: ActivityStatusBoard
    private let deviceId: String
    private var running = false
    static let healthAskedKey = "activity.health.authRequested"

    init(sink: ActivityPhoneSink, status: ActivityStatusBoard, deviceId: String) {
        self.sink = sink; self.status = status; self.deviceId = deviceId
    }

    func backfill(now: Date) async {
        guard !running, ActivitySettings.isRecording(at: now) else { return }
        running = true; defer { running = false }
        await backfillMotion(now: now)
        await backfillHealth(now: now)
    }

    private func backfillMotion(now: Date) async {
        guard CMMotionActivityManager.isActivityAvailable() else { status.set(.motion, .off("这台设备不支持运动活动")); return }
        switch CMMotionActivityManager.authorizationStatus() {
        case .denied, .restricted:
            status.set(.motion, .noPermission("设置 → 隐私与安全性 → 运动与健身 里允许 BetterCalendar")); return
        default: break
        }
        let from = now.addingTimeInterval(-48 * 3600)
        let samples: [PhoneActivityTransforms.MotionSample]
        do {
            let raw: [CMMotionActivity] = try await withCheckedThrowingContinuation { c in
                motion.queryActivityStarting(from: from, to: now, to: .main) { list, error in
                    if let error { c.resume(throwing: error) } else { c.resume(returning: list ?? []) }
                }
            }
            samples = raw.map { a in
                let label = a.automotive ? "automotive" : a.cycling ? "cycling" : a.running ? "running"
                    : a.walking ? "walking" : a.stationary ? "stationary" : "unknown"
                let conf = a.confidence == .high ? "high" : a.confidence == .medium ? "medium" : "low"
                return .init(start: a.startDate, activity: label, confidence: conf)
            }
        } catch {
            status.set(.motion, CMMotionActivityManager.authorizationStatus() == .denied
                       ? .noPermission("运动与健身权限被拒") : .failed("读运动历史失败：\(error.localizedDescription)"))
            return
        }
        await write(PhoneActivityTransforms.motionEvents(samples, deviceId: deviceId), source: .motion, now: now)
    }

    private func backfillHealth(now: Date) async {
        // W28：iPad 上的健康数据是 iPhone / 手表经 iCloud 同步来的副本——由 iPhone 回填；iPad 再记一遍会重复，
        // 还会把「睡觉 / 锻炼」记成发生在 iPad 上（不真实）。所以 iPad 不回填、也不弹健康授权。
        if ActivityDeviceKind.current == .ipad {
            status.set(.health, .off("iPad 不回填：这里的健康数据是 iPhone 同步来的副本，由 iPhone 记，免得重复"))
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else { status.set(.health, .off("这台设备没有健康数据")); return }
        let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let workoutType = HKObjectType.workoutType()
        if !UserDefaults.standard.bool(forKey: Self.healthAskedKey) {
            do { try await health.requestAuthorization(toShare: [], read: [sleepType, workoutType]); UserDefaults.standard.set(true, forKey: Self.healthAskedKey) }
            catch { status.set(.health, .failed("请求健康授权失败：\(error.localizedDescription)")); return }
        }
        let from = now.addingTimeInterval(-48 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: from, end: now)
        do {
            let sleep = try await samples(sleepType, predicate)
            let asleep: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
            let sleepSamples = sleep.compactMap { $0 as? HKCategorySample }.filter { asleep.contains($0.value) }
                .map { PhoneActivityTransforms.SleepSample(start: $0.startDate, end: $0.endDate) }
            var events = PhoneActivityTransforms.sleepEvents(sleepSamples, now: now, deviceId: deviceId)
            for w in try await samples(workoutType, predicate).compactMap({ $0 as? HKWorkout }) {
                events.append(ActivityEvent(id: ActivityStableID.make("workout-\(w.uuid.uuidString)"), at: w.startDate, kind: .other,
                                            source: .history, deviceId: deviceId, platform: "iOS",
                                            detail: ["signal": "workout", "activityType": String(w.workoutActivityType.rawValue),
                                                     "end": ActivityCodec.iso(w.endDate), "minutes": String(Int(w.duration / 60))]))
            }
            await write(events, source: .health, now: now)
            if events.isEmpty {
                // 读权限被拒时 HealthKit 只返回空（隐私设计，分不出「拒绝」和「没数据」）——如实写。
                status.set(.health, .waiting("最近 48 小时没读到睡眠/锻炼；若有数据却没读到，到「健康 → 共享 → App → BetterCalendar」打开读取"))
            }
        } catch {
            status.set(.health, .failed("读健康数据失败：\(error.localizedDescription)"))
        }
    }

    private func samples(_ type: HKSampleType, _ predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { c in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: 2000,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, s, e in
                if let e { c.resume(throwing: e) } else { c.resume(returning: s ?? []) }
            }
            health.execute(q)
        }
    }

    private func write(_ events: [ActivityEvent], source: ActivitySource, now: Date) async {
        do {
            let o = try await sink.record(events)
            status.working(source, at: events.map(\.at).max())
            if let e = o.uploadError { status.set(.cloudUpload, .failed("上传 iCloud 失败（\(o.pendingUpload) 条待传，稍后重试）：\(e)")) }
            else if o.uploaded > 0 || o.pendingUpload == 0 { status.working(.cloudUpload, at: now) }
        } catch {
            status.set(.storage, .failed("写本机日文件失败：\(error.localizedDescription)"))
        }
    }
}
#endif
