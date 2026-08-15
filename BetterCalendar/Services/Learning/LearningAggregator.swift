//
//  LearningAggregator.swift
//  BetterCalendar
//
//  学习层聚合桶（L3，SPEC §14.3 定稿公式的落地）：把 E4 残差样本折成每桶四个数字
//  （MEAN/DEV/count/lastUpdated，对数域），读取用三层回退+经验贝叶斯收缩混合。
//  桶层级：任务归属桶 → 族桶（闭集）→ kind 桶（fixed/anchor/free）→ 全局桶 → 出厂默认表。
//  隐私（§14.2）：聚合画像**本地文件**，不进 CloudKit（样本本体已随主容器同步，画像各端自算）。
//  ⚠️ 本层只算不用：排布仍用出厂默认 ×1.25——切生产=L5，判据（回放中位 APE 降 ≥15%
//  且无桶回退，可按桶部分启用）在 §14.4，攒数周真机数据后跑回放再裁。
//

import Foundation

/// 一个桶的四个数字（对数域）。
nonisolated struct BucketStats: Codable, Equatable, Sendable {
    var mean: Double = 0
    var dev: Double = 0
    var count: Int = 0
    var lastUpdated: Date = Date(timeIntervalSince1970: 0)
}

/// §14.3 全部数学（纯函数，可单测；参数=定稿初值，回放调参后改这里）。
nonisolated enum ResidualMath {
    static let alpha = 0.25              // MEAN 学习率（等效窗口约 7 样本）
    static let beta = 0.5                // DEV 响应快于均值（Jacobson 惯例）
    static let k = 1.0                   // 余量系数（将来「余量偏好」旋钮 ∈ {0.5,1,2}）
    static let winsorLo = 0.5            // winsorize 夹取（不对称边界=计划谬误重尾是 feature）
    static let winsorHi = 3.0
    static let devFloor = log(1.1)       // DEV 下限（防余量被巧合样本压零）
    static let shrinkCap = 20            // n 封顶（保漂移适应）
    static let pseudoCount = 6.0         // 收缩伪样本数 n0
    /// 出厂默认表（计划谬误基率）：与 DurationCalibration.defaultMultiplier 同源。
    static var priorMean: Double { log(DurationCalibration.defaultMultiplier) }
    static var priorDev: Double { devFloor }

    /// 样本 → 对数倍率（夹取；非法时长=nil 不产更新——脏数据不进桶）。
    static func logRatio(plannedMinutes: Int, actualMinutes: Int) -> Double? {
        guard plannedMinutes > 0, actualMinutes > 0 else { return nil }
        return log(min(max(Double(actualMinutes) / Double(plannedMinutes), winsorLo), winsorHi))
    }

    /// 双状态 EWMA 更新（Jacobson 式）。首样本直接落位（EWMA 从 0 起会被 prior 方向拖偏）。
    static func updated(_ s: BucketStats, m: Double, at t: Date) -> BucketStats {
        var s = s
        if s.count == 0 {
            s.mean = m
            s.dev = abs(m - priorMean)   // 首样本的离散度：对 prior 的偏离作初值
        } else {
            s.dev = (1 - beta) * s.dev + beta * abs(m - s.mean)
            s.mean = (1 - alpha) * s.mean + alpha * m
        }
        s.count += 1
        s.lastUpdated = t
        return s
    }

    /// 收缩权重 w = min(n,cap) / (min(n,cap) + n0)。
    static func shrinkWeight(count: Int) -> Double {
        let n = Double(min(count, shrinkCap))
        return n / (n + pseudoCount)
    }

    /// 收缩混合：读数 = w·本桶 + (1−w)·上层读数（n=0 自然=上层 → 冷启动免费、无悬崖）。
    static func mixed(bucket: BucketStats?, parent: (mean: Double, dev: Double)) -> (mean: Double, dev: Double) {
        guard let b = bucket, b.count > 0 else { return parent }
        let w = shrinkWeight(count: b.count)
        return (w * b.mean + (1 - w) * parent.mean, w * b.dev + (1 - w) * parent.dev)
    }

    /// 建议倍率 = e^(MEAN + k·max(DEV, floor))。
    static func suggestionMultiplier(mean: Double, dev: Double) -> Double {
        exp(mean + k * max(dev, devFloor))
    }
}

/// 聚合桶的存取与折算编排（本地 JSON 文件，ChangeTraceStore 同款模式）。
@MainActor
final class LearningAggregator {
    private let fileURL: URL

    nonisolated private struct File: Codable {
        var cursor = Date(timeIntervalSince1970: 0)   // 已折算样本的 createdAt 游标（时序折算）
        var buckets: [String: BucketStats] = [:]
    }
    private var file: File

    init(directory: URL? = nil) {
        let base = directory
            ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("BetterCalendar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("learning-buckets.json")
        file = (try? JSONDecoder().decode(File.self, from: Data(contentsOf: fileURL))) ?? File()
    }

    // MARK: 桶键

    static func taskKey(_ id: UUID) -> String { "task:\(id.uuidString)" }
    static func familyKey(_ f: String) -> String { "family:\(f)" }
    static func kindKey(isFixed: Bool, isAnchor: Bool) -> String {
        isFixed ? "kind:fixed" : (isAnchor ? "kind:anchor" : "kind:free")
    }
    static let globalKey = "global"

    // MARK: 折算（幂等：createdAt 游标，只折新样本；时序喂 EWMA）

    /// 把新样本折进四层桶。返回折算条数（观察窗/DevLog 用）。
    @discardableResult
    func fold(samples: [ResidualSample]) -> Int {
        let fresh = samples.filter { $0.createdAt > file.cursor }
            .sorted { $0.createdAt < $1.createdAt }
        guard !fresh.isEmpty else { return 0 }
        for s in fresh {
            guard let m = ResidualMath.logRatio(plannedMinutes: s.plannedMinutes,
                                                actualMinutes: s.actualMinutes) else { continue }
            var keys = [Self.globalKey, Self.kindKey(isFixed: s.isFixed, isAnchor: s.isAnchor)]
            if let f = familyOf(labels: s.labels) { keys.append(Self.familyKey(f)) }
            if let t = s.linkedTaskID { keys.append(Self.taskKey(t)) }
            for key in keys {
                file.buckets[key] = ResidualMath.updated(file.buckets[key] ?? BucketStats(),
                                                         m: m, at: s.createdAt)
            }
            file.cursor = max(file.cursor, s.createdAt)
        }
        persist()
        DevLog.shared.info("学习层", "聚合折算 \(fresh.count) 样本 → \(file.buckets.count) 桶")
        return fresh.count
    }

    private func familyOf(labels: [String]) -> String? {
        labels.first { $0.hasPrefix(ScheduledBlock.familyPrefix) }
            .map { String($0.dropFirst(ScheduledBlock.familyPrefix.count)) }
    }

    // MARK: 读取（三层回退 + 收缩混合链：默认表 → 全局 → kind → 族 → 任务）

    func read(taskID: UUID?, family: String?, isFixed: Bool = false, isAnchor: Bool = false)
        -> (mean: Double, dev: Double) {
        var r = (mean: ResidualMath.priorMean, dev: ResidualMath.priorDev)   // 出厂默认表
        r = ResidualMath.mixed(bucket: file.buckets[Self.globalKey], parent: r)
        r = ResidualMath.mixed(bucket: file.buckets[Self.kindKey(isFixed: isFixed, isAnchor: isAnchor)],
                               parent: r)
        if let f = family { r = ResidualMath.mixed(bucket: file.buckets[Self.familyKey(f)], parent: r) }
        if let t = taskID { r = ResidualMath.mixed(bucket: file.buckets[Self.taskKey(t)], parent: r) }
        return r
    }

    /// 建议倍率（L5 切生产前只进观察窗，不进排布）。
    func suggestionMultiplier(taskID: UUID?, family: String?,
                              isFixed: Bool = false, isAnchor: Bool = false) -> Double {
        let r = read(taskID: taskID, family: family, isFixed: isFixed, isAnchor: isAnchor)
        return ResidualMath.suggestionMultiplier(mean: r.mean, dev: r.dev)
    }

    /// 观察窗用：按样本量排序的桶清单。
    func bucketRows() -> [(key: String, stats: BucketStats)] {
        file.buckets.sorted { $0.value.count > $1.value.count }.map { ($0.key, $0.value) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(file) { try? data.write(to: fileURL, options: .atomic) }
    }
}
