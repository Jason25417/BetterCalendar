//
//  BenchAssertions.swift
//  BetterCalendar
//
//  试验台断言引擎：BenchOutput × BenchExpectation → 逐条判定（纯函数、可单测）。
//  标题匹配宽容：包含（忽略大小写）或 TitleMatch 相似度 ≥0.6——LLM 常改写标题（"写论文"→"论文写作"）。
//

import Foundation

enum BenchAssertions {

    struct Context {
        var referenceDay: Date
        var inputBlocks: [ScheduledBlock] = []   // refine/reflow 的输入（fixedUnmoved / flags 对照）
        var windDown: Date? = nil                // reflow 用例的收工线
        var graceMinutes: Int = 0
    }

    static func evaluate(_ expects: [BenchExpectation], output: BenchOutput,
                         context: Context) -> [BenchCheck] {
        expects.map { evaluateOne($0, output: output, context: context) }
    }

    // MARK: - 单条判定

    private static func evaluateOne(_ e: BenchExpectation, output: BenchOutput,
                                    context: Context) -> BenchCheck {
        func check(_ passed: Bool, _ detail: String) -> BenchCheck {
            BenchCheck(expectation: e, passed: passed, detail: detail)
        }
        let blocks = output.blocks

        switch e.kind {
        case .blockCountExact:
            let want = e.count ?? 0
            return check(blocks.count == want, "期望 \(want) 块，实得 \(blocks.count)")

        case .blockCountAtLeast:
            let want = e.count ?? 0
            return check(blocks.count >= want, "期望 ≥\(want) 块，实得 \(blocks.count)")

        case .hasBlock:
            let hit = matches(e.title, in: blocks)
            return check(!hit.isEmpty, hit.isEmpty ? "没找到「\(e.title ?? "")」" : "找到 \(hit.count) 块")

        case .hasBlockStart, .hasBlockEnd:
            guard let want = expectedTime(e, context: context) else {
                return check(false, "用例时间参数无效：\(e.hm ?? "nil")")
            }
            let hit = matches(e.title, in: blocks)
            guard !hit.isEmpty else { return check(false, "没找到「\(e.title ?? "")」") }
            let ok = hit.contains {
                abs(((e.kind == .hasBlockStart) ? $0.start : $0.end).timeIntervalSince(want)) < 60
            }
            let got = hit.map { hmText(e.kind == .hasBlockStart ? $0.start : $0.end) }
                .joined(separator: "/")
            // detail 带日期（2026-07-08 矩阵实测：模型把块放错了"天"，只显 HH:mm 会出现"期望实得相同却红"）
            return check(ok, ok ? "命中 \(hmText(want))" : "期望 \(hmText(want))，实得 \(got)")

        case .noBlock:
            let hit = matches(e.title, in: blocks)
            return check(hit.isEmpty, hit.isEmpty ? "无此块 ✓" : "出现了「\(hit[0].title)」")

        case .fixedUnmoved:
            let fixedIn = context.inputBlocks.filter(\.isFixed)
            var wrong: [String] = []
            for f in fixedIn {
                let same = blocks.first { $0.id == f.id } ?? matches(f.title, in: blocks).first
                guard let s = same,
                      abs(s.start.timeIntervalSince(f.start)) < 60,
                      abs(s.end.timeIntervalSince(f.end)) < 60 else { wrong.append(f.title); continue }
            }
            return check(wrong.isEmpty, wrong.isEmpty ? "固定块全部未动" : "固定块被动了：\(wrong.joined(separator: "、"))")

        case .noOverlaps:
            for i in blocks.indices {
                for j in blocks.indices where j > i {
                    let a = blocks[i], b = blocks[j]
                    guard a.start < b.end && b.start < a.end else { continue }
                    // 同并行组允许重叠（这正是并行的含义）
                    if let ga = a.parallelGroup, let gb = b.parallelGroup, ga == gb { continue }
                    return check(false, "重叠：\(a.title) × \(b.title)")
                }
            }
            return check(true, "无非法重叠")

        case .allTimingStyle:
            let want = TimingStyle(rawValue: e.style ?? "") ?? .light
            let wrong = blocks.filter { $0.timingStyle != want && !$0.isAnchor }
            return check(wrong.isEmpty,
                         wrong.isEmpty ? "全部 \(want.rawValue)" : "不符：\(wrong.map(\.title).joined(separator: "、"))")

        case .noTimingStyle:
            let banned = TimingStyle(rawValue: e.style ?? "") ?? .pomodoro
            let wrong = blocks.filter { $0.timingStyle == banned }
            return check(wrong.isEmpty,
                         wrong.isEmpty ? "无 \(banned.rawValue) ✓" : "抽风：\(wrong.map(\.title).joined(separator: "、")) 被标 \(banned.rawValue)")

        case .anchorFlag:
            let hit = matches(e.title, in: blocks)
            guard !hit.isEmpty else { return check(false, "没找到「\(e.title ?? "")」") }
            let want = e.flag ?? true
            let ok = hit.allSatisfy { $0.isAnchor == want }
            return check(ok, ok ? "isAnchor=\(want) ✓" : "isAnchor 应为 \(want)")

        case .fixedFlag:
            let hit = matches(e.title, in: blocks)
            guard !hit.isEmpty else { return check(false, "没找到「\(e.title ?? "")」") }
            let want = e.flag ?? true
            let ok = hit.allSatisfy { $0.isFixed == want }
            return check(ok, ok ? "isFixed=\(want) ✓" : "isFixed 应为 \(want)")

        case .sameStart:
            let a = matches(e.title, in: blocks), b = matches(e.title2, in: blocks)
            guard let fa = a.first, let fb = b.first else { return check(false, "两块没都找到") }
            let ok = abs(fa.start.timeIntervalSince(fb.start)) < 60
            return check(ok, ok ? "同起点 ✓" : "起点不同：\(hmText(fa.start)) vs \(hmText(fb.start))")

        case .orderBefore:
            let a = matches(e.title, in: blocks), b = matches(e.title2, in: blocks)
            guard let fa = a.map(\.start).min(), let fb = b.map(\.start).min() else {
                return check(false, "两块没都找到")
            }
            return check(fa < fb, fa < fb ? "顺序正确" : "「\(e.title ?? "")」没排在「\(e.title2 ?? "")」前")

        case .arrayOrderBefore:
            let ia = blocks.firstIndex { TitleMatch.similarity($0.title, e.title ?? "") >= 0.6 }
            let ib = blocks.firstIndex { TitleMatch.similarity($0.title, e.title2 ?? "") >= 0.6 }
            guard let ia, let ib else { return check(false, "两块没都找到") }
            return check(ia < ib, ia < ib ? "推荐顺序正确" : "「\(e.title ?? "")」没排在「\(e.title2 ?? "")」前")

        case .allWithinWindDown:
            guard let line = context.windDown?.addingTimeInterval(TimeInterval(context.graceMinutes * 60))
            else { return check(false, "用例缺收工线") }
            let offenders = blocks.filter { b in
                guard b.end > line, !b.isFixed, b.priority != .important else { return false }
                // 晚间豁免：输入里原 start 就在收工线后的块不算违规
                if let orig = context.inputBlocks.first(where: { $0.id == b.id }),
                   let wd = context.windDown, orig.start >= wd { return false }
                return true
            }
            return check(offenders.isEmpty,
                         offenders.isEmpty ? "全部收工线内（宽限 \(context.graceMinutes)min）"
                                           : "超线：\(offenders.map { "\($0.title)→\(hmText($0.end))" }.joined(separator: "、"))")

        case .deferredContains:
            let hit = matches(e.title, in: output.deferred)
            return check(!hit.isEmpty, hit.isEmpty ? "候补里没有「\(e.title ?? "")」" : "已进候补 ✓")

        case .deferredNotContains:
            let hit = matches(e.title, in: output.deferred)
            return check(hit.isEmpty, hit.isEmpty ? "未被让路 ✓" : "「\(e.title ?? "")」被挤进候补（不允许）")

        case .deferredEmpty:
            return check(output.deferred.isEmpty,
                         output.deferred.isEmpty ? "候补为空 ✓" : "候补 \(output.deferred.count) 块：\(output.deferred.map(\.title).joined(separator: "、"))")

        case .flagsUnchangedExcept:
            let allowed = (e.title ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            var wrong: [String] = []
            for r in blocks {
                if allowed.contains(where: { titleMatch($0, r.title) }) { continue }
                guard let o = context.inputBlocks.first(where: { $0.id == r.id })
                        ?? context.inputBlocks.first(where: { titleMatch($0.title, r.title) }) else { continue }
                if r.isFixed != o.isFixed { wrong.append("\(r.title).固定") }
                if r.priority != o.priority { wrong.append("\(r.title).★") }
                if r.timingStyle != o.timingStyle { wrong.append("\(r.title).计时") }
            }
            return check(wrong.isEmpty,
                         wrong.isEmpty ? "未提到的标志全部保持" : "被擅翻：\(wrong.joined(separator: "、"))")
        }
    }

    // MARK: - 工具

    /// 标题匹配：包含（忽略大小写）或相似度 ≥0.6。
    static func titleMatch(_ want: String, _ got: String) -> Bool {
        guard !want.isEmpty else { return false }
        return got.localizedCaseInsensitiveContains(want)
            || want.localizedCaseInsensitiveContains(got)
            || TitleMatch.similarity(want, got) >= 0.6
    }

    private static func matches(_ title: String?, in blocks: [ScheduledBlock]) -> [ScheduledBlock] {
        guard let t = title, !t.isEmpty else { return [] }
        return blocks.filter { titleMatch(t, $0.title) }
    }

    private static func expectedTime(_ e: BenchExpectation, context: Context) -> Date? {
        guard let hm = e.hm else { return nil }
        return BenchTime.date(hm: hm, dayOffset: e.dayOffset ?? 0, on: context.referenceDay)
    }

    /// 带日期的时刻文案（M-d HH:mm）：跨午夜/错日的失败必须能看出"差在哪一天"。
    private static func hmText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M-d HH:mm"
        return f.string(from: d)
    }
}
