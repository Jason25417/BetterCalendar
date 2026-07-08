//
//  BenchSuite.swift
//  BetterCalendar
//
//  试验台用例集：内置种子（Swift 定义，类型安全）+ App Support JSON（用户可编辑增删）。
//  首次运行把种子写成 JSON；之后以 JSON 为准（「恢复默认」可重置）。
//  用例时间全部相对参考日（跑时=逻辑明天），确定性、不依赖用户设置。
//

import Foundation

@MainActor
final class BenchSuiteStore {
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory
            ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("BetterCalendar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("algo-bench-cases.json")
    }

    var caseFileURL: URL { fileURL }

    /// 读用例：无文件/解不开 → 播种内置默认并返回之。
    func load() -> [BenchCase] {
        if let data = try? Data(contentsOf: fileURL),
           let cases = try? JSONDecoder().decode([BenchCase].self, from: data), !cases.isEmpty {
            return cases
        }
        let seed = Self.defaultCases
        save(seed)
        return seed
    }

    func save(_ cases: [BenchCase]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(cases) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func resetToDefaults() -> [BenchCase] {
        let seed = Self.defaultCases
        save(seed)
        return seed
    }

    // MARK: - 内置用例（P=解析 R=微调 F=reflow）

    static let defaultCases: [BenchCase] = [
        // ---------- 解析 ----------
        BenchCase(id: "P1", name: "跨午夜归属", capability: .parse, dimension: "理解力",
                  text: "晚上10点到12点半写论文，然后睡前看书到凌晨1点",
                  expects: [
                    .init(kind: .hasBlockStart, title: "论文", hm: "22:00"),
                    .init(kind: .hasBlockEnd, title: "论文", hm: "00:30", dayOffset: 1),
                    .init(kind: .hasBlockEnd, title: "看书", hm: "01:00", dayOffset: 1),
                    .init(kind: .noOverlaps),
                  ]),
        BenchCase(id: "P2", name: "时长算术+固定识别", capability: .parse, dimension: "理解力",
                  text: "上午9点开始写代码两小时，11点半开会一小时，会议雷打不动",
                  expects: [
                    .init(kind: .hasBlockStart, title: "代码", hm: "09:00"),
                    .init(kind: .hasBlockEnd, title: "代码", hm: "11:00"),
                    .init(kind: .hasBlockStart, title: "会", hm: "11:30"),
                    .init(kind: .fixedFlag, title: "会", flag: true),
                  ]),
        BenchCase(id: "P3", name: "服从：不要休息", capability: .parse, dimension: "服从性",
                  text: "早上9点到12点连续三小时深度工作，中间不要安排任何休息",
                  expects: [
                    .init(kind: .noBlock, title: "休息"),
                    .init(kind: .blockCountAtLeast, count: 1),
                    .init(kind: .noOverlaps),
                  ]),
        BenchCase(id: "P4", name: "服从：全部轻计时", capability: .parse, dimension: "服从性",
                  text: "下午2点读书一小时，4点跑步半小时，都用轻计时",
                  expects: [
                    .init(kind: .blockCountExact, count: 2),
                    .init(kind: .allTimingStyle, style: "light"),
                  ]),
        BenchCase(id: "P5", name: "防「全番茄」抽风", capability: .parse, dimension: "服从性",
                  text: "上午10点写报告三小时，下午3点整理邮箱半小时",
                  expects: [
                    .init(kind: .noTimingStyle, style: "pomodoro"),
                  ]),
        BenchCase(id: "P6", name: "并行意图", capability: .parse, dimension: "理解力",
                  text: "下午3点一边洗衣服一边听播客，一个小时",
                  expects: [
                    .init(kind: .blockCountAtLeast, count: 2),
                    .init(kind: .sameStart, title: "洗衣服", title2: "播客"),
                  ]),
        BenchCase(id: "P7", name: "锚点边界（防过度概化）", capability: .parse, dimension: "理解力",
                  text: "中午12点午饭半小时，下午1点到3点专心写作",
                  expects: [
                    .init(kind: .anchorFlag, title: "午饭", flag: true),
                    .init(kind: .anchorFlag, title: "写作", flag: false),
                  ]),

        // ---------- 微调（输入草稿：写作 09:00×2h / 会议 11:30×1h 固定 / 阅读 14:00×1h）----------
        BenchCase(id: "R1", name: "只改提到的块", capability: .refine, dimension: "服从性",
                  command: "把阅读挪到16点",
                  blocks: BenchSuiteStore.refineBase,
                  expects: [
                    .init(kind: .hasBlockStart, title: "阅读", hm: "16:00"),
                    .init(kind: .flagsUnchangedExcept, title: "阅读"),
                    .init(kind: .fixedUnmoved),
                    .init(kind: .blockCountExact, count: 3),
                  ]),
        BenchCase(id: "R2", name: "裸模型防擅翻标志", capability: .refine, dimension: "服从性",
                  command: "写作延长到三小时",
                  blocks: BenchSuiteStore.refineBase,
                  expects: [
                    .init(kind: .hasBlockEnd, title: "写作", hm: "12:00"),
                    .init(kind: .flagsUnchangedExcept, title: "写作"),
                    .init(kind: .hasBlockStart, title: "阅读", hm: "14:00"),
                  ]),
        BenchCase(id: "R3", name: "继承最初约束", capability: .refine, dimension: "服从性",
                  command: "整体往后挪一小时",
                  originalRequest: "上午写作两小时，11点半有个雷打不动的会，下午阅读一小时",
                  blocks: BenchSuiteStore.refineBase,
                  expects: [
                    .init(kind: .fixedUnmoved),
                    .init(kind: .hasBlockStart, title: "写作", hm: "10:00"),
                    .init(kind: .hasBlockStart, title: "阅读", hm: "15:00"),
                  ]),

        // ---------- reflow ----------
        BenchCase(id: "F1", name: "基本顺延+固定锚", capability: .reflow, dimension: "执行力",
                  blocks: [
                    .init(title: "写方案", startHM: "13:00", durationMinutes: 60),
                    .init(title: "部门会", startHM: "15:00", durationMinutes: 60, isFixed: true),
                    .init(title: "改简历", startHM: "14:00", durationMinutes: 90),
                  ],
                  fromHM: "13:40",
                  expects: [
                    .init(kind: .hasBlockStart, title: "写方案", hm: "13:40"),
                    .init(kind: .fixedUnmoved),
                    .init(kind: .noOverlaps),
                    .init(kind: .deferredEmpty),
                    .init(kind: .allWithinWindDown),
                  ]),
        BenchCase(id: "F2", name: "收工线取舍（宽限敏感）", capability: .reflow, dimension: "执行力",
                  blocks: [
                    .init(title: "打磨作品集", startHM: "20:00", durationMinutes: 180),
                    .init(title: "回邮件", startHM: "21:00", durationMinutes: 30),
                    .init(title: "夜宵散步", startHM: "23:30", durationMinutes: 30),
                  ],
                  fromHM: "20:00",
                  expects: [
                    .init(kind: .allWithinWindDown),
                    .init(kind: .hasBlockStart, title: "夜宵散步", hm: "23:30"),
                    .init(kind: .deferredNotContains, title: "夜宵散步"),
                    .init(kind: .noOverlaps),
                  ]),
        BenchCase(id: "F3", name: "★要紧事不让路", capability: .reflow, dimension: "执行力",
                  blocks: [
                    .init(title: "给导师回信", startHM: "21:00", durationMinutes: 120, priority: "important"),
                    .init(title: "整理桌面", startHM: "21:30", durationMinutes: 90),
                  ],
                  fromHM: "21:00",
                  expects: [
                    .init(kind: .deferredNotContains, title: "回信"),
                    .init(kind: .hasBlockStart, title: "回信", hm: "21:00"),
                    .init(kind: .deferredContains, title: "整理桌面"),
                    .init(kind: .allWithinWindDown),
                  ]),
        BenchCase(id: "F4", name: "并行组绑定", capability: .reflow, dimension: "执行力",
                  blocks: [
                    .init(title: "洗衣服", startHM: "19:00", durationMinutes: 60, parallelGroup: "家务"),
                    .init(title: "听讲座回放", startHM: "19:00", durationMinutes: 45, parallelGroup: "家务"),
                    .init(title: "晚自习", startHM: "20:00", durationMinutes: 120),
                  ],
                  fromHM: "18:00",
                  expects: [
                    .init(kind: .sameStart, title: "洗衣服", title2: "听讲座回放"),
                    .init(kind: .noOverlaps),
                    .init(kind: .deferredEmpty),
                    .init(kind: .allWithinWindDown),
                  ]),
        BenchCase(id: "F5", name: "全固定日", capability: .reflow, dimension: "执行力",
                  blocks: [
                    .init(title: "早会", startHM: "10:00", durationMinutes: 30, isFixed: true),
                    .init(title: "客户演示", startHM: "14:00", durationMinutes: 60, isFixed: true),
                  ],
                  fromHM: "09:30",
                  expects: [
                    .init(kind: .fixedUnmoved),
                    .init(kind: .deferredEmpty),
                    .init(kind: .blockCountExact, count: 2),
                  ]),
    ]

    private static let refineBase: [BenchBlockSpec] = [
        .init(title: "写作", startHM: "09:00", durationMinutes: 120),
        .init(title: "会议", startHM: "11:30", durationMinutes: 60, isFixed: true),
        .init(title: "阅读", startHM: "14:00", durationMinutes: 60),
    ]
}
