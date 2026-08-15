//
//  EngineWindowView.swift
//  BetterCalendar
//
//  引擎观察窗（开发期，P1 配套——Jason 2026-07-31 同意；同试验台/试衣间先例，M8 摘除）：
//  把统一时间线引擎的内部状态直接画出来，每完成一批（P1a–P1e）往里加一节——
//  正式时间线 UI（P2）之前，用它亲眼验收引擎行为。
//  P1a：图钉序列 ±2 天 + 现在指针 + 当前逻辑日区间。
//  P1b：流动性排布试算（合成场景演示 FluidLayoutEngine：钉死/软锚/队列/溢出；真实数据接线=P1e）。
//  P1c：溢出裁决（SpillResolver：顺延/回池/溶解/升提议——含 DDL 挡路与连续顺延升级演示）。
//  P1d/E4：学习层采集端（今日快照状态 + 昨日残差样本——真数据，非合成）。
//  刷新=手动按钮 + 打开时（不做周期刷新——menu bar TimelineView 卡死教训，保守起见观察窗同守）。
//

import SwiftUI

struct EngineWindowView: View {
    @Environment(\.appTheme) private var theme
    @State private var now = Date.now
    @State private var seedStatus = ""   // CloudKit 播种结果回执（开发件）

    private var window: DateInterval {
        DateInterval(start: PinSchedule.dayBoundary(atOrBefore: now).addingTimeInterval(-2 * 86400),
                     end: PinSchedule.dayBoundary(after: now).addingTimeInterval(2 * 86400))
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd EEE HH:mm"
        return f
    }()

    private func label(_ kind: PinKind) -> (String, String) {
        switch kind {
        case .dayBoundary: ("跨日", "pin.fill")
        case .workEnd: ("收工", "moon.zzz")
        case .eveningStart: ("傍晚", "sunset")
        }
    }

    var body: some View {
        List {
            Section("当前逻辑日（两根跨日图钉之间）") {
                let iv = PinSchedule.dayInterval(containing: now)
                Text("\(Self.fmt.string(from: iv.start))  →  \(Self.fmt.string(from: iv.end))")
                    .font(.system(.body, design: .monospaced))
                Text("时长 \(String(format: "%.1f", iv.duration / 3600)) 小时（跨时区日可能 ≠24h，属正常）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("图钉序列（±2 天）") {
                let pins = PinSchedule.pins(in: window)
                ForEach(Array(pins.enumerated()), id: \.offset) { _, pin in
                    let (name, icon) = label(pin.kind)
                    HStack {
                        Image(systemName: icon)
                            .foregroundStyle(pin.kind == .dayBoundary ? theme.accent : .secondary)
                            .frame(width: 20)
                        Text(name).font(.caption).frame(width: 36, alignment: .leading)
                        Text(Self.fmt.string(from: pin.time))
                            .font(.system(.body, design: .monospaced))
                        if pin.time <= now, PinSchedule.pins(in: window).first(where: { $0.time > now })?.time ?? .distantFuture > now,
                           pin == pins.last(where: { $0.time <= now }) {
                            Spacer()
                            Text("← 现在在这根钉之后").font(.caption).foregroundStyle(theme.accent)
                        }
                    }
                    .opacity(pin.time <= now ? 0.5 : 1)   // 过去的钉凝固变淡
                }
            }
            Section("排布试算（P1b 合成场景：收工 18:00）") {
                let demo = Self.demoLayout()
                ForEach(Array(demo.placed.enumerated()), id: \.offset) { _, p in
                    HStack {
                        Text(Self.demoTitles[p.id] ?? "?").frame(width: 70, alignment: .leading)
                        Text("\(Self.hm(p.start)) – \(Self.hm(p.end))")
                            .font(.system(.body, design: .monospaced))
                    }
                }
                ForEach(Array(demo.overflow.enumerated()), id: \.offset) { _, id in
                    HStack {
                        Text(Self.demoTitles[id] ?? "?").frame(width: 70, alignment: .leading)
                        Text("→ 溢出：\(Self.spillText(for: id))")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Section("溢出裁决演示（P1c 合成候选）") {
                ForEach(Array(Self.spillDemo().enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.0).frame(width: 110, alignment: .leading)
                        Text(row.1).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("CloudKit schema 播种（开发件；Deploy 前后各点一次）") {
                Text(seedStatus.isEmpty ? CloudKitSchemaSeeder.status() : seedStatus)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("播种") { seedStatus = CloudKitSchemaSeeder.seed() }
                    Button("清除") { seedStatus = CloudKitSchemaSeeder.cleanup() }
                        .tint(.primary)
                    Spacer()
                }
                Text("Debug 运行=CloudKit Development 环境。播种 → 等同步 → Console(Development) 看到 DayPlanSnapshot / ResidualSample / LongTask 新字段 → Deploy → 回来点「清除」。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("引擎对照（E5b 影子：协调器状态 + 升格演示）") {
                if let co = TimelineCoordinator.sharedForDev {
                    Text(co.lastComputeAt.map { "最近重算：\(Self.fmt.string(from: $0))" } ?? "尚未重算（未开工日=影子闸拦截）")
                        .font(.caption)
                    Text("写回：\(co.lastWriteNote) · 手改冷却 \(co.manualHolds.count) 块")
                        .font(.caption).foregroundStyle(.secondary)
                    if !co.softSpilledIDs.isEmpty {
                        Text("软溢出标记：\(co.softSpilledIDs.count) 块（收工复盘时硬执行）")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text("协调器未接线（测试/预览环境）").font(.caption).foregroundStyle(.secondary)
                }
                // 升格行为演示（合成）：族聚簇 + setup 间隙 + 并行槽 + 校准呼吸口
                ForEach(Array(Self.upgradeDemo().enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.0).frame(width: 110, alignment: .leading)
                        Text(row.1).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            Section("学习层聚合桶（L3 真数据：只算不用，切生产=L5 回放门控）") {
                let agg = LearningAggregator()
                let rows = agg.bucketRows()
                if rows.isEmpty {
                    Text("还没有聚合桶（等 E4 攒出残差样本后启动自动折算）")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(rows.prefix(8).enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.key).font(.system(.caption, design: .monospaced))
                                .frame(width: 150, alignment: .leading).lineLimit(1)
                            Text("n=\(row.stats.count) · ×\(String(format: "%.2f", ResidualMath.suggestionMultiplier(mean: row.stats.mean, dev: row.stats.dev)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("全局建议倍率 ×\(String(format: "%.2f", agg.suggestionMultiplier(taskID: nil, family: nil)))（排布现用出厂 ×\(String(format: "%.2f", DurationCalibration.defaultMultiplier))）")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Section("学习层采集（E4 真数据）") {
                let learning = LearningStore()
                let today = DayContext.logicalStartOfDay(now)
                if let snap = learning.snapshot(for: today) {
                    Text("今日快照：已存（\(snap.items.count) 块，\(Self.hm(snap.createdAt)) 首次确认时）")
                        .font(.caption)
                } else {
                    Text("今日快照：尚未确认写入").font(.caption).foregroundStyle(.secondary)
                }
                let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
                let samples = learning.samples(on: yesterday)
                if samples.isEmpty {
                    Text("昨日残差样本：无（无快照/未回填/待兜底折算）")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, sm in
                        HStack {
                            Text(sm.title).frame(width: 90, alignment: .leading).lineLimit(1)
                            Text("计划 \(sm.plannedMinutes)m → 实际 \(sm.actualMinutes)m · ×\(String(format: "%.2f", Double(sm.actualMinutes) / Double(max(1, sm.plannedMinutes)))) · \(sm.sourceRaw)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { now = .now } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
        }
        .onAppear { now = .now }
        .frame(minWidth: 380, minHeight: 420)
    }

    // MARK: P1b 排布试算的合成场景（固定 UUID → 标题映射，演示引擎行为）

    private static let demoIDs = (meeting: UUID(), writing: UUID(), reading: UUID(),
                                  lunch: UUID(), star: UUID(), extra: UUID())
    static let demoTitles: [UUID: String] = [
        demoIDs.meeting: "会议(钉死)", demoIDs.writing: "写作", demoIDs.reading: "阅读",
        demoIDs.lunch: "午饭(±60)", demoIDs.star: "★要紧事", demoIDs.extra: "杂务",
    ]

    static func demoLayout() -> FluidLayoutResult {
        let cal = Calendar.current
        let day = cal.startOfDay(for: .now)
        func t(_ h: Int, _ mi: Int = 0) -> Date {
            cal.date(byAdding: .minute, value: h * 60 + mi, to: day)!
        }
        let modules = [
            FluidModule(id: demoIDs.meeting, title: "会议", duration: 3600,
                        fluidity: .pinned, plannedStart: t(12)),
            FluidModule(id: demoIDs.lunch, title: "午饭", duration: 1800,
                        fluidity: .soft(60), plannedStart: t(12)),
            FluidModule(id: demoIDs.writing, title: "写作", duration: 2 * 3600,
                        fluidity: .free, plannedStart: t(9)),
            FluidModule(id: demoIDs.reading, title: "阅读", duration: 90 * 60,
                        fluidity: .free, plannedStart: t(14)),
            FluidModule(id: demoIDs.star, title: "要紧事", duration: 90 * 60,
                        fluidity: .free, priority: .important, plannedStart: t(15)),
            FluidModule(id: demoIDs.extra, title: "杂务", duration: 2 * 3600,
                        fluidity: .free, plannedStart: t(16)),
        ]
        return FluidLayoutEngine.layOut(modules: modules, from: t(9), hardEnd: t(18))
    }

    /// P1c：真实溢出块的裁决文案（demo 场景：都是工作块→顺延明天）。
    static func spillText(for id: UUID) -> String {
        let c = SpillCandidate(id: id, title: demoTitles[id] ?? "?")
        return decisionText(SpillResolver.resolve(c, reference: .now))
    }

    /// P1c/E5c 裁定版：合成候选矩阵——默认收待办区、生活锚溶解、DDL 挡路升提议、显式 forward/ask。
    static func spillDemo() -> [(String, String)] {
        let ref = Date.now
        let tomorrow4am = DayContext.logicalWindow(forLabel: DayContext.logicalDay(offset: 1, from: ref)).start
        let cases: [SpillCandidate] = [
            SpillCandidate(id: UUID(), title: "工作块"),
            SpillCandidate(id: UUID(), title: "池投放件", fromPool: true),
            SpillCandidate(id: UUID(), title: "生活锚", isAnchor: true),
            SpillCandidate(id: UUID(), title: "今晚DDL", deadline: tomorrow4am.addingTimeInterval(-3600)),
            SpillCandidate(id: UUID(), title: "显式排明天", policyOverride: .forward),
            SpillCandidate(id: UUID(), title: "显式ask", policyOverride: .ask),
        ]
        return cases.map { ($0.title, decisionText(SpillResolver.resolve($0, reference: ref))) }
    }

    private static func decisionText(_ d: SpillDecision) -> String {
        switch d {
        case .forward(let day): "顺延 → \(hm(DayContext.logicalWindow(forLabel: day).start))（明日窗口起点）"
        case .returnToPool: "收待办区（明早露脸）"
        case .dissolve: "溶解（零记录，明天照常）"
        case .escalate(.deadlineBlocksForward): "⚠️ 升提议：DDL 挡路（晨间置顶）"
        case .escalate(.userAskedToAsk): "⚠️ 升提议：用户要求每次过问"
        }
    }

    static func hm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// E5b 升格演示（合成）：写作×2（同族相邻+首块后免 setup）→ 沟通（跨族但轻档 s=0）→
    /// 编码（跨族重档 s=12 间隙）+ 并行组同起点 + 校准占线（呼吸口=下一块起点晚于上一块名义终点）。
    static func upgradeDemo() -> [(String, String)] {
        let cal = Calendar.current
        let day = cal.startOfDay(for: .now)
        func t(_ h: Int, _ mi: Int = 0) -> Date { cal.date(byAdding: .minute, value: h * 60 + mi, to: day)! }
        let ids = (w1: UUID(), code: UUID(), w2: UUID(), talk: UUID(), pa: UUID(), pb: UUID())
        let modules = [
            FluidModule(id: ids.w1, title: "写第3章", duration: 3600, fluidity: .free, plannedStart: t(9),
                        occupiedDuration: 3600 * 1.25, family: "写作"),
            FluidModule(id: ids.code, title: "修 bug", duration: 3600, fluidity: .free, plannedStart: t(10),
                        occupiedDuration: 3600 * 1.25, family: "编码"),
            FluidModule(id: ids.w2, title: "改第2章", duration: 1800, fluidity: .free, plannedStart: t(11),
                        occupiedDuration: 1800 * 1.25, family: "写作"),
            FluidModule(id: ids.talk, title: "回邮件", duration: 1800, fluidity: .free, plannedStart: t(12),
                        family: "沟通协调"),
            FluidModule(id: ids.pa, title: "洗衣(并行A)", duration: 1800, fluidity: .free, plannedStart: t(13),
                        parallelGroup: "parallel:家务"),
            FluidModule(id: ids.pb, title: "听播客(并行B)", duration: 1800, fluidity: .free, plannedStart: t(13),
                        parallelGroup: "parallel:家务"),
        ]
        let titles: [UUID: String] = [ids.w1: "写第3章", ids.code: "修 bug", ids.w2: "改第2章",
                                      ids.talk: "回邮件", ids.pa: "洗衣(并行A)", ids.pb: "听播客(并行B)"]
        let r = FluidLayoutEngine.layOut(modules: modules, from: t(9), hardEnd: t(18))
        return r.placed.map { (titles[$0.id] ?? "?", "\(hm($0.start)) – \(hm($0.end))") }
            + r.overflow.map { (titles[$0] ?? "?", "→ 溢出") }
    }
}
