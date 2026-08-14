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

    /// P1c：合成候选矩阵——四策略与三升级局面各一例。
    static func spillDemo() -> [(String, String)] {
        let ref = Date.now
        let tomorrow4am = DayContext.logicalWindow(forLabel: DayContext.logicalDay(offset: 1, from: ref)).start
        let cases: [SpillCandidate] = [
            SpillCandidate(id: UUID(), title: "工作块"),
            SpillCandidate(id: UUID(), title: "池投放件", fromPool: true),
            SpillCandidate(id: UUID(), title: "生活锚", isAnchor: true),
            SpillCandidate(id: UUID(), title: "今晚DDL", deadline: tomorrow4am.addingTimeInterval(-3600)),
            SpillCandidate(id: UUID(), title: "滚了3次", spillCount: 3),
            SpillCandidate(id: UUID(), title: "显式ask", policyOverride: .ask),
        ]
        return cases.map { ($0.title, decisionText(SpillResolver.resolve($0, reference: ref))) }
    }

    private static func decisionText(_ d: SpillDecision) -> String {
        switch d {
        case .forward(let day): "顺延 → \(hm(DayContext.logicalWindow(forLabel: day).start))（明日窗口起点）"
        case .returnToPool: "回池（等下次投放）"
        case .dissolve: "溶解（零记录，明天照常）"
        case .escalate(.deadlineBlocksForward): "⚠️ 升提议：DDL 挡路推不过去"
        case .escalate(.repeatedSpills(let n)): "⚠️ 升提议：已连续顺延 \(n) 次"
        case .escalate(.userAskedToAsk): "⚠️ 升提议：用户要求每次过问"
        }
    }

    static func hm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
