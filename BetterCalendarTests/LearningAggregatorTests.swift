//
//  LearningAggregatorTests.swift
//  BetterCalendarTests
//
//  L3 聚合桶（§14.3 公式）+ L4 六合成画像验机制（§14.4：每画像验一件事，各有通过标准）。
//  纪律：聚合器注入独立临时目录（不碰真画像文件）；样本 createdAt 手工递增（游标幂等靠它）。
//

import Testing
import Foundation
import SwiftData
@testable import BetterCalendar

@MainActor
@Suite struct LearningAggregatorTests {
    private let cal = Calendar.current
    private func at(_ day: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: h))!
    }

    private func makeAggregator() -> LearningAggregator {
        LearningAggregator(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("agg-test-\(UUID().uuidString)", isDirectory: true))
    }

    /// 造样本（不进 SwiftData 容器——聚合器只读字段；createdAt 递增保时序与游标）。
    private func sample(day: Int, planned: Int, actual: Int,
                        family: String? = nil, taskID: UUID? = nil,
                        isAnchor: Bool = false) -> ResidualSample {
        let s = ResidualSample(dayLabel: at(day), blockID: UUID(), title: "样本",
                               labels: family.map { [ScheduledBlock.familyPrefix + $0] } ?? [],
                               linkedTaskID: taskID, isFixed: false, isAnchor: isAnchor,
                               plannedStart: at(day, 9), plannedMinutes: planned,
                               actualStart: at(day, 9), actualMinutes: actual, source: .live)
        s.createdAt = at(day, 20)
        return s
    }

    // MARK: L3 机制

    /// 折算幂等（createdAt 游标）：同批样本喂两次，第二次零折算、桶不变。
    @Test func foldIsIdempotentByCursor() {
        let agg = makeAggregator()
        let batch = (1...5).map { sample(day: $0, planned: 60, actual: 90) }
        #expect(agg.fold(samples: batch) == 5)
        let before = agg.read(taskID: nil, family: nil)
        #expect(agg.fold(samples: batch) == 0, "游标幂等")
        let after = agg.read(taskID: nil, family: nil)
        #expect(before == after)
    }

    /// 冷启动免费：零样本时读数=出厂默认表（×1.25 带 DEV 下限余量）。
    @Test func coldStartEqualsFactoryDefault() {
        let agg = makeAggregator()
        let m = agg.suggestionMultiplier(taskID: nil, family: nil)
        let expected = ResidualMath.suggestionMultiplier(mean: log(1.25), dev: ResidualMath.devFloor)
        #expect(abs(m - expected) < 0.001)
        #expect(m > 1.25, "默认建议含 k·DEV 余量，略高于纯倍率")
    }

    // MARK: L4 六合成画像（§14.4 每画像验一个机制）

    /// 画像① 教科书低估者（恒 ×1.5）：MEAN 收敛到 ln1.5 附近，建议 ≥1.5（余量只会更高）。
    @Test func personaChronicUnderestimator() {
        let agg = makeAggregator()
        agg.fold(samples: (1...20).map { sample(day: $0, planned: 60, actual: 90) })
        let r = agg.read(taskID: nil, family: nil)
        #expect(abs(r.mean - log(1.5)) < 0.08, "MEAN 收敛 ln1.5±")
        let m = agg.suggestionMultiplier(taskID: nil, family: nil)
        #expect(m >= 1.5 && m < 2.0, "建议=1.5×上浮余量，不失控")
    }

    /// 画像② 高方差者（0.8/2.0 交替）：DEV 显著 → 建议明显高于几何均值（验 DEV 的价值）。
    @Test func personaHighVariance() {
        let agg = makeAggregator()
        let ratios: [(Int, Int)] = (1...20).map { i in i % 2 == 0 ? (60, 48) : (60, 120) }
        agg.fold(samples: ratios.enumerated().map { i, r in
            sample(day: i + 1, planned: r.0, actual: r.1) })
        let r = agg.read(taskID: nil, family: nil)
        let geoMean = exp(r.mean)
        let m = agg.suggestionMultiplier(taskID: nil, family: nil)
        #expect(r.dev > 0.3, "方差被 DEV 捕捉")
        #expect(m > geoMean * 1.3, "高波动者的建议带显著余量（这正是 DEV 存在的意义）")
    }

    /// 画像③ 漂移者（前 20 天 ×1.0 → 后 20 天 ×2.0）：EWMA 跟上新水平（近期主导）。
    @Test func personaDrifter() {
        let agg = makeAggregator()
        var batch = (1...20).map { sample(day: $0, planned: 60, actual: 60) }
        batch += (21...40).map { sample(day: $0, planned: 60, actual: 120) }
        agg.fold(samples: batch)
        let r = agg.read(taskID: nil, family: nil)
        #expect(exp(r.mean) > 1.7, "漂移后 EWMA 收敛到新水平（若是全history均值只有 ~1.41）")
    }

    /// 画像④ 分桶差异者：族 A 恒 ×2、族 B 恒 ×1 → 两族建议分开；小样本被收缩拉向上层。
    @Test func personaBucketDivergence() {
        let agg = makeAggregator()
        var batch: [ResidualSample] = []
        for i in 1...15 { batch.append(sample(day: i, planned: 60, actual: 120, family: "编码")) }
        for i in 16...30 { batch.append(sample(day: i, planned: 60, actual: 60, family: "沟通协调")) }
        agg.fold(samples: batch)
        let a = agg.suggestionMultiplier(taskID: nil, family: "编码")
        let b = agg.suggestionMultiplier(taskID: nil, family: "沟通协调")
        #expect(a > b + 0.3, "两族建议显著分开")
        // 收缩：只有 2 个样本的新任务桶，读数应被上层（族）主导而非自身极端值
        let task = UUID()
        agg.fold(samples: [sample(day: 31, planned: 60, actual: 180, family: "编码", taskID: task),
                           sample(day: 32, planned: 60, actual: 180, family: "编码", taskID: task)])
        // 收缩验在 MEAN 上（建议含 k·DEV 余量，极端小样本的余量本来就该大——那是 DEV 的职责）
        let tMean = exp(agg.read(taskID: task, family: "编码").mean)
        let aMean = exp(agg.read(taskID: nil, family: "编码").mean)
        #expect(tMean < 2.9, "2 样本的极端桶（×3）被收缩拉住（w=2/8=0.25，MEAN 不直接吃 ×3）")
        #expect(tMean > aMean, "但方向性信息保留（比族桶高）")
    }

    /// 画像⑤ 脏数据者：零/负时长样本不产更新（准入之外聚合层再兜一道）。
    @Test func personaDirtyData() {
        let agg = makeAggregator()
        agg.fold(samples: [sample(day: 1, planned: 0, actual: 60),
                           sample(day: 2, planned: 60, actual: 0)])
        let r = agg.read(taskID: nil, family: nil)
        #expect(r.mean == ResidualMath.priorMean, "脏样本零污染（读数仍=默认表）")
    }

    /// 画像⑥ 长尾爆表者（一次 ×10）：winsorize 夹到 ×3，MEAN 不被单点炸飞。
    @Test func personaOutlierWinsorized() {
        let agg = makeAggregator()
        var batch = (1...10).map { sample(day: $0, planned: 60, actual: 66) }   // 稳定 ×1.1
        batch.append(sample(day: 11, planned: 60, actual: 600))                  // ×10 爆表
        agg.fold(samples: batch)
        // 注：global 与 kind:free 两桶装同一批样本，混合链会叠两次桶信号——数值比单桶直觉高。
        // 实算：夹取后建议 ≈×2.19；若不夹取（m=ln10）同链算出 ≈×4.8——这就是 winsorize 的价值。
        let m = agg.suggestionMultiplier(taskID: nil, family: nil)
        #expect(m < 2.5, "单点爆表被夹取，建议不失控（无 winsorize 同链 ≈×4.8）")
        #expect(exp(agg.read(taskID: nil, family: nil).mean) < 1.45, "MEAN 只被夹取值轻推（≈1.39）")
    }
}
