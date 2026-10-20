//
//  AxisAutoScroller.swift
//  BetterCalendar
//
//  W26b：拖动时贴近视口上 / 下边缘就自动滚（跨天拖到「明天下午」这类够不着的地方才拖得到）。
//  - 手指（鼠标）进到边缘带里才滚，越靠边越快；离开边缘带、松手即停；滚到轴的两端（可显示范围）自然停住；
//  - 落点 = 手指在视口里的位移 + 这次拖动期间自动滚过的距离（再按 5 分钟吸附，吸附在 commit 里做，与原来同一处）；
//  - 滚动位置每帧都在变，但只记在不被观察的属性里（不让整个时间轴每帧重算）；只有「自动滚过的距离」是被观察的，
//    而且只有正在被拖的那一块读它。
//

import Foundation
import CoreGraphics
import Observation

@Observable @MainActor
final class AxisAutoScroller {
    /// 边缘带多高（pt）：手指进到离视口上 / 下边这么近就开始滚。
    /// W31b：按视口高度定（12%，夹在 24–56pt）——iPhone 上轴视口只有两三百 pt 时，固定 56pt 两条带吃掉近一半，普通拖动就会飞走。
    nonisolated static func edge(viewport h: CGFloat) -> CGFloat { min(56, max(24, h * 0.12)) }
    /// 进边缘带后先停这么久才开始滚（秒）：拖动途中擦过边不会立刻跑。
    nonisolated static let dwell: TimeInterval = 0.3
    /// 拖动手势的坐标系 = 视口（时间轴的 ScrollView 上命名）。
    nonisolated static let viewportSpace = "bc.axis.viewport"
    /// 最快多快（pt/秒）：手指贴到最边上时。W31b：900 → 300（52pt/小时 → 约每秒 6 小时；今晚到明早约两秒，跨天仍够得着；
    /// 原来约每秒 17 小时，稍一贴边就跑出几个小时）。
    nonisolated static let maxSpeed: CGFloat = 300

    // 每帧都会变的量：不被观察（写它不触发任何视图重算）
    @ObservationIgnored var offsetY: CGFloat = 0
    @ObservationIgnored var viewportHeight: CGFloat = 0
    @ObservationIgnored var contentHeight: CGFloat = 0
    /// 视图挂上：把视口滚到某个偏移。
    @ObservationIgnored var scrollTo: ((CGFloat) -> Void)?

    /// 这次拖动期间自动滚过的距离（pt，往下为正）。只有正在拖的那一块读它（预览跟着滚动走）。
    private(set) var delta: CGFloat = 0

    @ObservationIgnored private var startOffset: CGFloat = 0
    @ObservationIgnored private var fingerY: CGFloat?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var active = false
    /// 每次拖动一个编号：上一轮循环收尾时不会误清 / 误续这一轮的循环。
    @ObservationIgnored private var generation = 0

    /// 开始一次拖动。
    func begin() {
        guard !active else { return }
        active = true
        generation += 1
        startOffset = offsetY
        delta = 0
    }

    /// 手指此刻在视口里的位置（视口坐标，顶 = 0）。进到边缘带就开始滚。
    func update(fingerY y: CGFloat) {
        guard active else { return }
        fingerY = y
        if loop == nil, Self.velocity(fingerY: y, viewport: viewportHeight) != 0 { startLoop() }
    }

    /// 松手 / 取消：停住，返回这次自动滚过的总距离（加到落点上）。
    @discardableResult
    func end() -> CGFloat {
        loop?.cancel(); loop = nil
        let d = delta
        active = false; fingerY = nil; delta = 0
        return d
    }

    private func startLoop() {
        let gen = generation
        loop = Task { [weak self] in
            var last = ContinuousClock.now
            let entered = last   // 这一轮循环 = 手指这次进边缘带的时刻（离开就结束循环，再进来重新计停留）
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled, self.active, self.generation == gen, let y = self.fingerY else { break }
                let t = ContinuousClock.now
                let dt = (t - last) / .seconds(1)
                last = t
                let v = Self.velocity(fingerY: y, viewport: self.viewportHeight)
                guard v != 0 else { break }   // 离开边缘带：停
                guard (t - entered) / .seconds(1) >= Self.dwell else { continue }   // W31b：先停一下再滚
                let next = Self.nextOffset(current: self.offsetY, velocity: v, dt: CGFloat(dt),
                                           content: self.contentHeight, viewport: self.viewportHeight)
                guard next != self.offsetY else { continue }   // 已到轴的一端：停在那里，手指挪回来还能接着拖
                self.scrollTo?(next)
                self.offsetY = next   // 不等滚动回调：下一帧按新位置算
                self.delta = next - self.startOffset
            }
            if let self, self.generation == gen { self.loop = nil }
        }
    }

    /// 滚动速度（pt/秒；往下为正，0 = 不滚）：边缘带里线性加速，越靠边越快。纯函数、可单测。
    nonisolated static func velocity(fingerY y: CGFloat, viewport h: CGFloat) -> CGFloat {
        guard h >= 120 else { return 0 }   // 视口太矮（小窗口）：不自动滚，免得一按就跑
        let edge = edge(viewport: h)
        if y < edge { return -maxSpeed * min(1, (edge - y) / edge) }
        if y > h - edge { return maxSpeed * min(1, (y - (h - edge)) / edge) }
        return 0
    }

    /// 下一帧的偏移：夹在 [0, 内容高 − 视口高] 里（轴的两端就是可显示 / 可拖的范围）。纯函数、可单测。
    nonisolated static func nextOffset(current: CGFloat, velocity: CGFloat, dt: CGFloat, content: CGFloat, viewport: CGFloat) -> CGFloat {
        let maxOffset = max(0, content - viewport)
        return min(maxOffset, max(0, current + velocity * max(0, min(dt, 0.1))))
    }
}

/// 底边把手的触控范围（W26b）：iPhone 至少 44pt 高（HIG），把手本身的细条不变。
nonisolated enum AxisHitArea {
    /// 往块里伸 inside（块太短时少伸，留给「拖动整块」），往块下伸 outside——**只伸进空档**：
    /// 下面紧挨着别的块 / 日界线时不伸过去，不抢邻居的点按与拖动；滚动不受影响（要先按住 0.2 秒才算拉边）。纯函数、可单测。
    static func resize(blockHeight h: CGFloat, gapBelow: CGFloat, target: CGFloat) -> (inside: CGFloat, outside: CGFloat) {
        let inside = min(max(6, h * 0.35), 22, h)
        let outside = max(0, min(target - inside, gapBelow))
        return (inside, outside)
    }
}
