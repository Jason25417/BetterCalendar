//
//  TimelineAxisView.swift
//  BetterCalendar
//
//  W23「今天」页的时间轴（方案 A：一根竖轴，计划与实际同在一根轴上）。
//  - 一根连续可滚的轴，跨今天前 3 天到后 7 天；逻辑日之间是 4:00 的日界线图钉（带日期）；
//  - 「现在」线 = 闸门：线以上只有蓝色做成的事，线以下是绿色计划；正在做的那块跨在线上（蓝到现在、绿是剩下的）；
//  - 默认视口 =「闸门恒为主」：打开 / 点「今天」都把「现在」放在视口上部三分之一处（R10：打开即朝前）；
//  - 顶上的日子条 =「跳到那天」（滚过去，不换页）；
//  - 直接操作：拖绿色块挪时间（W26 起可拖进别的日子，今天到 7 天后）、拉底边改时长（5 分钟吸附；iPhone 长按后拖，
//    Mac 直接拖）；点一下改标题 / 性质 / 删除；
//    放不下（规则不许）就写明原因、块回到原位——绝不悄悄挤。过去的 / 做成的 / 你的日历都不能拖。
//  - 性能：W26b 起 11 段日子用普通 VStack（不懒加载）：拖动时自动滚过一天以上，懒加载会把被拖那块所在的一段卸掉、
//    手势中途断掉；固定高度的 11 段一次排好，打开时滚到闸门的偏移也是精确的。滚动 / 自动滚的每帧位置不进视图状态
//    （见 AxisAutoScroller），不会每帧重算整根轴。闸门每分钟离散跳一次（页面内，不是菜单栏 label——那里绝不放周期刷新）。
//

import SwiftUI

struct TimelineAxisView<DayMenu: View>: View {
    @Bindable var axis: TimelineAxisModel
    /// 点一下计划块：交给页面打开编辑（页面负责先切到那一天）。
    var onEdit: (AxisItem) -> Void
    /// 日子条右侧的「这一天」菜单（页面提供）。参数 = 视口里正在看的那一天。
    @ViewBuilder var dayMenu: (Date) -> DayMenu

    @Environment(\.appTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    /// 每小时多高：跟随 Dynamic Type 变大（U9：字号开大不破版——字变大，时间轴也变高，短块照样放得下一行字）。
    @ScaledMetric(relativeTo: .caption) private var pointsPerHour: CGFloat = 52
    @ScaledMetric(relativeTo: .caption2) private var gutter: CGFloat = 42
    @State private var position = ScrollPosition(edge: .top)
    @State private var viewportHeight: CGFloat = 0
    /// W26：视口摘要（正在看哪一天 / 闸门在不在视口里）。只在**摘要变了**时更新——原来每一帧滚动都写 offsetY，
    /// 整个 body（含 days() 组装）跟着每帧重算，滚起来白白耗电掉帧。
    @State private var viewport = Viewport(visibleDay: nil, gateVisible: true)
    @State private var didInitialScroll = false
    /// W26：上次离开前台的时刻（回来时离开够久 → 重新把闸门放回视口，R10「打开即朝前」）。
    @State private var leftActiveAt: Date?
    /// W26b：拖动贴边自动滚。
    @State private var scroller = AxisAutoScroller()

    struct Viewport: Equatable {
        var visibleDay: Date?
        var gateVisible: Bool
    }

    /// 回到前台时离开超过这么久，就把视口重新对准「现在」（短暂切走再回来不跳，免得打断你正在看的地方）。
    static var reanchorAfter: TimeInterval { 15 * 60 }

    /// 闸门在视口里的位置（从上往下的比例）：上面留一点做成的事，大部分给接下来的。
    static var gateViewportFraction: CGFloat { 0.3 }

    private var geometry: AxisGeometry { AxisGeometry(labels: axis.labels, pointsPerHour: pointsPerHour) }

    var body: some View {
        let days = axis.days()
        let geo = geometry
        VStack(alignment: .leading, spacing: 6) {
            jumpBar(geo)
            if let notice = axis.notice {
                MessageStrip(icon: "info.circle", tint: theme.looseTint, text: notice, textStyle: .primary) {
                    Button("知道了") { axis.notice = nil }.buttonStyle(.plain).font(.caption).foregroundStyle(theme.accent)
                }
                .accessibilityIdentifier("bc.today.axis.notice")
            }
            if let err = axis.occupiedError {
                MessageStrip(icon: "calendar.badge.exclamationmark", tint: .orange, text: err)
            }
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(days) { day in
                        AxisDaySection(day: day, geo: geo, now: axis.now, gutter: gutter,
                                       isToday: day.label == axis.todayLabel,
                                       busy: axis.isCommitting, scroller: scroller,
                                       onMove: { item, start in Task { await axis.commitDrag(item, start: start) } },
                                       onResize: { item, end in Task { await axis.commitResize(item, end: end) } },
                                       onTap: onEdit)
                            .frame(height: geo.section(day.label).height)
                            .id(day.label)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition($position)
            .coordinateSpace(.named(AxisAutoScroller.viewportSpace))
            // 每帧的位置只交给自动滚（不被观察的属性，不触发重算）
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in scroller.offsetY = y }
            .onScrollGeometryChange(for: Viewport.self, of: { g in
                Self.viewport(offsetY: g.contentOffset.y, height: g.containerSize.height, geo: geo, now: axis.now)
            }) { _, v in viewport = v }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.height }) { _, h in
                viewportHeight = h
                scroller.viewportHeight = h
                if !didInitialScroll, h > 0 { didInitialScroll = true; scrollToGate(geo) }
            }
            .accessibilityIdentifier("bc.today.timeline")
        }
        // 过了 4:00 日界线：轴的日子整体往后挪一天（每一段的位置都变了）→ 重新对准「现在」，不让视口停在错位的地方
        .onChange(of: axis.todayLabel) { _, _ in if viewportHeight > 0 { scrollToGate(geometry) } }
        .onAppear {
            let binding = $position
            scroller.scrollTo = { y in binding.wrappedValue.scrollTo(y: y) }
        }
        .onChange(of: geo.height, initial: true) { _, h in scroller.contentHeight = h }
        .task {
            FeatureUsage.seen(.todayAxis)
            await axis.reload()
            // 闸门每分钟离散跳一次（对齐到整分）；页面消失即停（.task 随视图生命周期取消）
            while !Task.isCancelled {
                let sec = Calendar.current.component(.second, from: .now)
                try? await Task.sleep(for: .seconds(60 - sec))
                guard !Task.isCancelled else { break }
                await axis.tick()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                let away = leftActiveAt.map { Date.now.timeIntervalSince($0) } ?? 0
                leftActiveAt = nil
                Task {
                    await axis.reload()
                    // 离开够久再回来 = 新的一次「打开」：闸门回到视口上部（R10）
                    if away >= Self.reanchorAfter, viewportHeight > 0 { scrollToGate(geometry) }
                }
            } else if leftActiveAt == nil {
                leftActiveAt = .now
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReconcileService.planChangedExternally)) { _ in
            Task { await axis.reload(includeCalendar: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: TimelineCoordinator.planEdited)) { _ in
            Task { await axis.reload(includeCalendar: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ExecutionProgressSignal.changed)) { _ in
            Task { await axis.reload(includeCalendar: false) }
        }
    }

    // MARK: 跳到那天

    /// 视口摘要（纯函数）：正在看的那一天 = 视口上部三分之一处那一刻所属的逻辑日；闸门在不在视口里。
    static func viewport(offsetY: CGFloat, height: CGFloat, geo: AxisGeometry, now: Date) -> Viewport {
        let probe = geo.time(atY: offsetY + max(0, height) * gateViewportFraction)
        let gateY = geo.y(now)
        return Viewport(visibleDay: DayContext.logicalStartOfDay(probe),
                        gateVisible: height <= 0 || (gateY >= offsetY && gateY <= offsetY + height))
    }

    private func scrollToGate(_ geo: AxisGeometry) {
        let y = geo.y(axis.now) - viewportHeight * Self.gateViewportFraction
        position.scrollTo(y: max(0, y))
    }

    private func scrollToDay(_ label: Date, _ geo: AxisGeometry) {
        if label == axis.todayLabel { scrollToGate(geo); return }
        position.scrollTo(y: geo.section(label).top)
    }

    @ViewBuilder private func jumpBar(_ geo: AxisGeometry) -> some View {
        let visible = viewport.visibleDay ?? axis.todayLabel
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(axis.labels, id: \.self) { label in
                        let selected = label == visible
                        Button {
                            FeatureUsage.used(.todayAxisDayJump, label == axis.todayLabel ? "今天" : (label < axis.todayLabel ? "过去" : "往后"))
                            scrollToDay(label, geo)
                        } label: {
                            Text(Self.chipLabel(label, today: axis.todayLabel))
                                .font(.callout)
                                .lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(selected ? AnyShapeStyle(theme.accent.opacity(0.18))
                                                                    : AnyShapeStyle(.quaternary.opacity(0.5))))
                                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("跳到 " + TimelineAxisComposer.dayLabel(label, now: axis.now))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            if !viewport.gateVisible {
                Button {
                    FeatureUsage.used(.todayAxisBackToNow)
                    scrollToGate(geo)
                } label: {
                    Label("回到现在", systemImage: "scope").font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("bc.today.axis.backToNow")
                .onAppear { FeatureUsage.seen(.todayAxisBackToNow) }
            }
            dayMenu(visible)
        }
    }

    static func chipLabel(_ label: Date, today: Date) -> String {
        let offset = Calendar.current.dateComponents([.day], from: today, to: label).day ?? 0
        switch offset {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        case -1: return "昨天"
        default: return label.formatted(.dateTime.weekday(.abbreviated)) + " " + label.formatted(.dateTime.day())
        }
    }
}

// MARK: - 一个逻辑日

private struct AxisDaySection: View {
    let day: AxisDay
    let geo: AxisGeometry
    let now: Date
    let gutter: CGFloat
    let isToday: Bool
    let busy: Bool
    let scroller: AxisAutoScroller
    let onMove: (AxisItem, Date) -> Void
    let onResize: (AxisItem, Date) -> Void
    let onTap: (AxisItem) -> Void

    @Environment(\.appTheme) private var theme
    @State private var drag: AxisDrag?

    private var top: CGFloat { geo.section(day.label).top }
    private func localY(_ t: Date) -> CGFloat { geo.y(t) - top }

    var body: some View {
        GeometryReader { proxy in
            let trackX = gutter + 6
            let trackW = max(40, proxy.size.width - trackX - 2)
            ZStack(alignment: .topLeading) {
                hourGrid(width: proxy.size.width)
                ForEach(day.pins.filter { $0.kind != .dayBoundary }) { pin in
                    pinMarker(pin, x: trackX, width: trackW)
                }
                ForEach(day.items) { item in
                    block(item, trackX: trackX, trackW: trackW)
                }
                if isToday, day.window.contains(now) { gateLine(width: proxy.size.width, trackX: trackX) }
                if let boundary = day.pins.first(where: { $0.kind == .dayBoundary }) { dayPin(boundary, width: proxy.size.width) }
            }
        }
        .zIndex(drag == nil ? 0 : 1)   // 拖着的块可以越出这一段画（越界会被规则拒绝）
    }

    // MARK: 刻度

    private func hourGrid(width: CGFloat) -> some View {
        let hours = Self.hourMarks(in: day.window)
        return ZStack(alignment: .topLeading) {
            ForEach(hours, id: \.self) { h in
                let y = localY(h)
                Rectangle().fill(.quaternary.opacity(0.6)).frame(width: max(0, width - gutter), height: 0.5)
                    .offset(x: gutter, y: y)
                if h != day.window.start, !(isToday && abs(y - localY(now)) < 18) {   // 让出闸门的字
                    Text(PlanEditRules.hm(h)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: gutter - 4, alignment: .trailing)
                        .offset(y: y - 7)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    static func hourMarks(in window: DateInterval) -> [Date] {
        var out: [Date] = []
        var t = window.start
        let cal = Calendar.current
        while t < window.end {
            out.append(t)
            guard let next = cal.date(byAdding: .hour, value: 1, to: t) else { break }
            t = next
        }
        return out
    }

    // MARK: 图钉

    /// 4:00 日界线：一根零长度的图钉，带日期（流水线从这里进入下一个逻辑日）。
    private func dayPin(_ pin: AxisPin, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Label(pin.label, systemImage: "pin.fill")
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(isToday ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(theme.bg, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
            Rectangle().fill(.secondary.opacity(0.5)).frame(height: 1)
        }
        .frame(width: width, alignment: .leading)
        .offset(y: -1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("日界线 4:00，进入\(pin.label)")
    }

    /// 收工线 / 截止：零长度的细线 + 一句中性的字（不是警示）。
    private func pinMarker(_ pin: AxisPin, x: CGFloat, width: CGFloat) -> some View {
        let icon = pin.kind == .deadline ? "flag.checkered" : "moon.haze"
        return HStack(spacing: 4) {
            Rectangle().fill(.secondary.opacity(0.45)).frame(height: 1)
            Label(pin.label + " " + PlanEditRules.hm(pin.at), systemImage: icon)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .fixedSize()
        }
        .frame(width: width, alignment: .trailing)
        .offset(x: x, y: localY(pin.at) - 7)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    // MARK: 闸门

    /// 「现在」：中性的承接口（R4：不用警示色、不做紧迫渲染、不做连续动画）。
    private func gateLine(width: CGFloat, trackX: CGFloat) -> some View {
        // 字收在左侧刻度栏里（不压住块）：「现在」+ 时刻两行，线横贯轨道
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("现在").font(.caption2.weight(.semibold))
                Text(PlanEditRules.hm(now)).font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.primary)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(width: gutter - 2)
            .padding(.vertical, 2)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.5)))
            Rectangle().fill(.primary.opacity(0.55)).frame(height: 1.5)
        }
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .alignmentGuide(.top) { d in d[VerticalAlignment.center] }
        .offset(y: localY(now))
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
        .accessibilityIdentifier("bc.today.axis.gate")
        .accessibilityLabel("现在 \(PlanEditRules.hm(now))：上面是做成的事，下面是接下来的计划")
    }

    // MARK: 块

    private func block(_ item: AxisItem, trackX: CGFloat, trackW: CGFloat) -> some View {
        let laneW = trackW / CGFloat(max(1, item.lanes))
        let x = trackX + laneW * CGFloat(item.lane)
        var start = item.start, end = item.end
        if let d = drag, d.itemID == item.id {
            let dy = d.dy + scroller.delta   // 手指位移 + 这次拖动期间自动滚过的距离
            switch d.mode {
            case .move:
                let ns = AxisGeometry.snap(geo.time(atY: geo.y(item.start) + dy))
                end = ns.addingTimeInterval(item.end.timeIntervalSince(item.start)); start = ns
            case .resize:
                let ne = AxisGeometry.snap(geo.time(atY: geo.y(item.end) + dy))
                end = max(ne, item.start.addingTimeInterval(5 * 60))
            }
        }
        let h = max(6, geo.y(end) - geo.y(start) - 1)
        let dragging = drag?.itemID == item.id
        // W26 跨天拖：拖进别的逻辑日时，块上的时间带上落到哪一天（「明天 09:00–10:00」），松手前就看得见
        let landing = DayContext.logicalStartOfDay(start)
        let dayHint = dragging && landing != day.label ? PlanEditRules.relativeDayName(landing, now: now) : nil
        return AxisBlockView(item: item, start: start, end: end, height: h, dragging: dragging, dayHint: dayHint)
            .frame(width: max(10, laneW - 3), height: h, alignment: .topLeading)
            .overlay(alignment: .bottom) {
                if item.isDraggable { resizeHandle(item, height: h) }
            }
            .offset(x: x, y: localY(start))
            .zIndex(dragging ? 2 : (item.kind == .plan ? 1 : 0))
            .modifier(MoveGesture(enabled: item.isDraggable && !busy, onChange: { dy, fingerY in
                track(item, .move, dy: dy, fingerY: fingerY)
            }, onEnd: { dy in
                let total = dy + finish()
                onMove(item, geo.time(atY: geo.y(item.start) + total))
            }, onCancel: cancel))
            .onTapGesture { if item.kind == .plan, item.blockID != nil { onTap(item) } }
    }

    // MARK: 拖动 + 贴边自动滚

    private func track(_ item: AxisItem, _ mode: AxisDrag.Mode, dy: CGFloat, fingerY: CGFloat?) {
        if drag == nil { scroller.begin() }
        drag = AxisDrag(itemID: item.id, mode: mode, dy: dy)
        if let fingerY { scroller.update(fingerY: fingerY) }
    }

    /// 松手：停住自动滚，返回这次滚过的距离（加到落点上）。
    private func finish() -> CGFloat {
        drag = nil
        return scroller.end()
    }

    /// 手势被系统打断（来电、切走）：什么都不改，块回原位。
    private func cancel() {
        guard drag != nil else { return }
        drag = nil
        scroller.end()
    }

    /// 这一块下面到下一个东西（任一块 / 这一天的日界线）之间的空档（pt）。保守：不看并排的列，只要时间上后面有东西就算。
    private func gapBelow(_ item: AxisItem) -> CGFloat {
        let next = day.items.filter { $0.id != item.id && $0.start >= item.end }.map(\.start).min()
        let limit = min(next ?? day.window.end, day.window.end)
        return max(0, geo.y(limit) - geo.y(item.end))
    }

    /// 底边把手：拉它改结束时刻（开始不动）。
    private func resizeHandle(_ item: AxisItem, height h: CGFloat) -> some View {
        #if os(macOS)
        let area = (inside: CGFloat(10), outside: CGFloat(0))   // 鼠标指得准，范围照旧
        #else
        let area = AxisHitArea.resize(blockHeight: h, gapBelow: gapBelow(item), target: 44)
        #endif
        let active = drag?.itemID == item.id && drag?.mode == .resize
        return ZStack(alignment: .top) {
            Color.clear
            Capsule().fill(.secondary.opacity(active ? 0.6 : 0.25))
                .frame(width: 28, height: 4)
                .offset(y: max(0, area.inside - 7))   // 细条仍贴在块的底边里面（视觉不变）
        }
        .frame(width: 76, height: area.inside + area.outside)
        .contentShape(Rectangle())
        .offset(y: area.outside)   // 触控范围往块下伸进空档
        #if os(macOS)
        .pointerStyle(.frameResize(position: .bottom))
        #endif
        .modifier(MoveGesture(enabled: !busy, highPriority: true, pressDuration: 0.2, onChange: { dy, fingerY in
            track(item, .resize, dy: dy, fingerY: fingerY)
        }, onEnd: { dy in
            let total = dy + finish()
            onResize(item, geo.time(atY: geo.y(item.end) + total))
        }, onCancel: cancel))
        .accessibilityLabel("拉动改「\(item.title)」的结束时间")
    }
}

private struct AxisDrag: Equatable {
    enum Mode { case move, resize }
    var itemID: String
    var mode: Mode
    var dy: CGFloat
}

/// 拖动手势：Mac = 鼠标直接拖；iPhone = 长按后拖（不和滚动抢）。报纵向位移 + 手指在视口里的位置（贴边自动滚用）。
/// 位移按视口坐标量：自动滚时手指不动、内容在动，位移不变，滚过的距离由 AxisAutoScroller 另算再加上。
private struct MoveGesture: ViewModifier {
    var enabled: Bool
    var highPriority = false
    var pressDuration: Double = 0.3
    /// fingerY = nil：iPhone 长按刚成立、手指还没动（块先浮起来，还不知道位置）。
    var onChange: (_ dy: CGFloat, _ fingerY: CGFloat?) -> Void
    var onEnd: (CGFloat) -> Void
    /// 手势没走到 onEnded 就没了（被系统打断）。
    var onCancel: () -> Void = {}
    @GestureState private var live = false

    private var space: CoordinateSpace { .named(AxisAutoScroller.viewportSpace) }

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else {
            #if os(macOS)
            let g = DragGesture(minimumDistance: 3, coordinateSpace: space)
                .updating($live) { _, s, _ in s = true }
                .onChanged { onChange($0.translation.height, $0.location.y) }
                .onEnded { onEnd($0.translation.height) }
            let c = content.onChange(of: live) { was, now in if was, !now { onCancel() } }
            if highPriority { c.highPriorityGesture(g) } else { c.gesture(g).pointerStyle(.grabIdle) }
            #else
            let g = LongPressGesture(minimumDuration: pressDuration)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: space))
                .updating($live) { v, s, _ in if case .second(true, _) = v { s = true } }
                .onChanged { v in
                    if case .second(true, let d?) = v { onChange(d.translation.height, d.location.y) }
                    else if case .second(true, nil) = v { onChange(0, nil) }
                }
                .onEnded { v in
                    if case .second(true, let d?) = v { onEnd(d.translation.height) } else { onCancel() }
                }
            let c = content.onChange(of: live) { was, now in if was, !now { onCancel() } }
            if highPriority { c.highPriorityGesture(g) } else { c.gesture(g) }
            #endif
        }
    }
}

// MARK: - 块的长相（形状冗余：计划=描边感，实际=实心感，你的日历=灰；色彩不作唯一通道，U9）

private struct AxisBlockView: View {
    let item: AxisItem
    let start: Date
    let end: Date
    let height: CGFloat
    let dragging: Bool
    var dayHint: String? = nil
    @Environment(\.appTheme) private var theme

    private var tint: Color {
        switch item.kind {
        case .plan: theme.plannedTint
        case .actual: theme.actualTint
        case .occupied: .gray
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        VStack(alignment: .leading, spacing: 1) {
            if height >= 14 {
                HStack(spacing: 3) {
                    if let icon = leadingIcon { Image(systemName: icon).font(.caption2).foregroundStyle(tint) }
                    Text(item.title).font(.caption.weight(.medium)).lineLimit(height >= 40 ? 2 : 1)
                        .foregroundStyle(item.kind == .occupied ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Spacer(minLength: 0)
                    tags
                }
            }
            if height >= 32 || dragging {
                Text(subtitle).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, height >= 14 ? 3 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill, in: shape)
        .overlay(stroke(shape))
        .clipShape(shape)
        .opacity(item.isAnchor ? 0.6 : 1)
        .shadow(color: dragging ? .black.opacity(0.18) : .clear, radius: dragging ? 6 : 0, y: dragging ? 2 : 0)   // 拖起来的块是真浮起来的（阴影白名单）
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var leadingIcon: String? {
        switch item.kind {
        case .actual: item.isRunning ? "timer" : "checkmark"
        case .occupied: "calendar"
        case .plan: item.isFixed ? "lock" : nil
        }
    }

    @ViewBuilder private var tags: some View {
        if item.kind == .plan {
            if item.isImportant {
                Text("尽早").font(.caption2).foregroundStyle(theme.accent).lineLimit(1).fixedSize()
            }
            if item.isPinned {
                Label("钉住", systemImage: "pin").labelStyle(.titleAndIcon).font(.caption2)
                    .foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                    .help("你亲手拖过：今天之内自动调整绕开它")
            }
        }
    }

    private var subtitle: String {
        let span = (dayHint.map { $0 + " " } ?? "") + PlanEditRules.span(start, end)
        switch item.kind {
        case .occupied: return span + (item.calendarName.map { " · \($0)" } ?? "")
        case .actual: return item.isRunning ? "正在做 · 从 \(PlanEditRules.hm(start))" : span
        case .plan: return item.isRunning ? "接下来 · 到 \(PlanEditRules.hm(end))" : span
        }
    }

    private var fill: Color {
        switch item.kind {
        case .plan: tint.opacity(dragging ? 0.2 : 0.09)
        case .actual: tint.opacity(0.3)
        case .occupied: Color.gray.opacity(0.16)
        }
    }

    @ViewBuilder private func stroke(_ shape: RoundedRectangle) -> some View {
        switch item.kind {
        case .plan: shape.strokeBorder(tint.opacity(0.85), lineWidth: 1.2)
        case .actual: shape.strokeBorder(.clear)
        case .occupied: shape.strokeBorder(Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
        }
    }

    private var accessibility: String {
        let span = PlanEditRules.span(start, end)
        switch item.kind {
        case .plan:
            var s = "计划：\(item.title)，\(span)"
            if item.isFixed { s += "，固定" }
            if item.isPinned { s += "，钉住" }
            if item.isDraggable { s += "。点一下编辑，拖动改时间" }
            return s
        case .actual: return (item.isRunning ? "正在做：" : "做成了：") + "\(item.title)，\(span)"
        case .occupied: return "你的日历\(item.calendarName.map { "「\($0)」" } ?? "")：\(item.title)，\(span)，只读"
        }
    }
}
