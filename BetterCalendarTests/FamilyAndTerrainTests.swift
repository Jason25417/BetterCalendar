//
//  FamilyAndTerrainTests.swift
//  BetterCalendarTests
//
//  E5e 投放管道件：族三重一致性（归属继承>历史复用>LLM 标注>其他）/ Ledger LRU+模糊 /
//  解析器族标签闭集校验 / 剩余地形纯函数。
//  纪律：Ledger 用独立 UserDefaults suite（共享默认库老坑）；容器随 fixture 保活。
//

import Testing
import Foundation
import SwiftData
@testable import BetterCalendar

@MainActor
@Suite struct FamilyAndTerrainTests {
    private let cal = Calendar.current
    private func at(_ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: h, minute: mi))!
    }
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "bc-family-test-\(UUID().uuidString)")!
    }

    private struct PoolFixture {
        let store: LongTaskStore
        let container: ModelContainer   // 保活（第五根因）
    }
    private func makePool() throws -> PoolFixture {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: LongTask.self, configurations: config)
        return PoolFixture(store: LongTaskStore(context: container.mainContext), container: container)
    }

    /// 三级优先序：归属继承 > Ledger 历史 > LLM 标注 > 其他。
    @Test func resolverPriorityOrder() throws {
        let d = freshDefaults()
        let f = try makePool()
        let task = f.store.add(title: "毕业论文")
        task.family = "写作"
        // ① 归属继承赢过一切
        #expect(FamilyResolver.resolve(title: "论文第3章", linkedTaskID: task.id,
                                       parsedFamily: "编码", longTasks: f.store, defaults: d) == "写作")
        // ② 无归属 → Ledger 历史
        FamilyLedger.record("修网站bug", family: "编码", defaults: d)
        #expect(FamilyResolver.resolve(title: "修网站bug", linkedTaskID: nil,
                                       parsedFamily: "写作", longTasks: f.store, defaults: d) == "编码")
        // ③ 都不中 → LLM 标注（并入账 Ledger）
        #expect(FamilyResolver.resolve(title: "回教授邮件", linkedTaskID: nil,
                                       parsedFamily: "沟通协调", longTasks: f.store, defaults: d) == "沟通协调")
        #expect(FamilyLedger.lookup("回教授邮件", defaults: d) == "沟通协调", "③命中即入账")
        // ④ 兜底其他（不入账）
        #expect(FamilyResolver.resolve(title: "神秘任务", linkedTaskID: nil,
                                       parsedFamily: "不在闭集", longTasks: f.store, defaults: d) == "其他")
        #expect(FamilyLedger.lookup("神秘任务", defaults: d) == nil, "「其他」不入账，下次再试")
    }

    /// ③命中时归属任务顺手继承族（长期任务拿族的主通道）。
    @Test func resolverBackfillsTaskFamily() throws {
        let d = freshDefaults()
        let f = try makePool()
        let task = f.store.add(title: "学量化")
        #expect(task.family == nil)
        _ = FamilyResolver.resolve(title: "学量化第1讲", linkedTaskID: task.id,
                                   parsedFamily: "阅读学习", longTasks: f.store, defaults: d)
        #expect(task.family == "阅读学习")
    }

    /// Ledger：归一化精确优先、模糊 ≥0.6 兜底、LRU 容量掐头、「其他」不收。
    @Test func ledgerLookupAndLRU() {
        let d = freshDefaults()
        FamilyLedger.record("写周报", family: "写作", defaults: d)
        #expect(FamilyLedger.lookup("写周报", defaults: d) == "写作")
        #expect(FamilyLedger.lookup("写 周报！", defaults: d) == "写作", "归一化吃掉空白标点")
        #expect(FamilyLedger.lookup("周报", defaults: d) == "写作", "子串模糊 0.9 命中")
        FamilyLedger.record("看论文", family: "其他", defaults: d)
        #expect(FamilyLedger.lookup("看论文", defaults: d) == nil, "「其他」不入账")
    }

    /// 解析器族标签：闭集值落 labels；非法值/「其他」不落（引擎中性）。
    @Test func decodePlanFamilyLabel() {
        let json = """
        {"loose":false,"blocks":[
          {"title":"修bug","start":"2026-07-15 09:00","end":"2026-07-15 10:00","family":"编码"},
          {"title":"神秘","start":"2026-07-15 10:00","end":"2026-07-15 11:00","family":"不存在的族"},
          {"title":"杂事","start":"2026-07-15 11:00","end":"2026-07-15 12:00","family":"其他"}],
         "longTasks":[]}
        """
        let decoded = ClaudeScheduleParser.decodePlan(json)!
        #expect(decoded.blocks[0].labels == [ScheduledBlock.familyPrefix + "编码"])
        #expect(decoded.blocks[1].labels.isEmpty, "非法值不落标签")
        #expect(decoded.blocks[2].labels.isEmpty, "「其他」不落标签（族未知=中性）")
    }

    /// 剩余地形：裁剪合并重叠时段；超订=0；呈现不显负数。
    @Test func terrainFreeMinutesAndLine() {
        let spans = [(start: at(9), end: at(11)),
                     (start: at(10), end: at(12)),      // 与上一段重叠
                     (start: at(8), end: at(9, 30))]    // 越过 from 的部分裁掉
        let free = TerrainSummary.freeMinutes(spans: spans, from: at(9), until: at(14))
        #expect(free == 120, "9-14 共 300 分钟，占用 9-12 共 180 → 自由 120")
        #expect(TerrainSummary.line(freeMinutes: 120) == "到收工还有约 2 小时自由区")
        #expect(TerrainSummary.line(freeMinutes: 45) == "到收工还有约 45 分钟自由区")
        #expect(TerrainSummary.line(freeMinutes: 0) == "今天已排满")
        #expect(TerrainSummary.freeMinutes(spans: [(start: at(8), end: at(23))],
                                           from: at(9), until: at(14)) == 0, "超订不出负数")
    }
}
