//
//  EngineWindowView.swift
//  BetterCalendar
//
//  引擎观察窗（开发期，P1 配套——Jason 2026-07-31 同意；同试验台/试衣间先例，M8 摘除）：
//  把统一时间线引擎的内部状态直接画出来，每完成一批（P1a–P1e）往里加一节——
//  正式时间线 UI（P2）之前，用它亲眼验收引擎行为。
//  P1a：图钉序列 ±2 天 + 现在指针 + 当前逻辑日区间。
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
        }
        .toolbar {
            ToolbarItem {
                Button { now = .now } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
        }
        .onAppear { now = .now }
        .frame(minWidth: 380, minHeight: 420)
    }
}
