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

    /// seen 旁车文件：记录「这台机器的用例文件见过哪些内置 id」——种子演进只补**从没见过的新增**，
    /// 用户主动删掉的用例绝不复活（删除是编辑，编辑归用户）。
    private var seenURL: URL { fileURL.deletingPathExtension().appendingPathExtension("seen.json") }

    /// 读用例：无文件/解不开 → 播种内置默认并返回之。
    /// **种子演进合并**（0.31，踩坑：0.28 加的 S/W 用例被用户机上的旧种子文件整体盖住、试验台里根本看不见）：
    /// 用户文件优先（保留其编辑与删除），但内置默认里**这台机器从没见过的新增 id** 自动补进并回写。
    func load() -> [BenchCase] {
        if let data = try? Data(contentsOf: fileURL),
           var cases = try? JSONDecoder().decode([BenchCase].self, from: data), !cases.isEmpty {
            let known = Set(cases.map(\.id))
            let seen = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: seenURL))) ?? known
            let missing = Self.defaultCases.filter { !known.contains($0.id) && !seen.contains($0.id) }
            if !missing.isEmpty {
                cases.append(contentsOf: missing)
                DevLog.shared.info("试验台", "用例种子演进：补入内置新增 \(missing.map(\.id).joined(separator: ","))")
            }
            // 内置修订下发（0.31.2，首例=W1 撤「开森」断言）：内置 rev 比本地新 → 覆盖该条
            //（修订是有意为之，会盖掉对该条的手改；用户删掉的仍不复活——新增归 seen 管，修订只碰还在的）。
            var revised: [String] = []
            for def in Self.defaultCases {
                if let i = cases.firstIndex(where: { $0.id == def.id }), (cases[i].rev ?? 0) < (def.rev ?? 0) {
                    cases[i] = def
                    revised.append(def.id)
                }
            }
            if !revised.isEmpty { DevLog.shared.info("试验台", "用例修订下发：\(revised.joined(separator: ","))") }
            if !missing.isEmpty || !revised.isEmpty { save(cases) }
            writeSeen(seen.union(known).union(Self.defaultCases.map(\.id)))
            return cases
        }
        let seed = Self.defaultCases
        save(seed)
        writeSeen(Set(seed.map(\.id)))
        return seed
    }

    private func writeSeen(_ ids: Set<String>) {
        if let data = try? JSONEncoder().encode(ids.sorted()) {
            try? data.write(to: seenURL, options: .atomic)
        }
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
        BenchCase(id: "P8", name: "用餐默认补排", capability: .parse, dimension: "服从性",
                  text: "上午9点到晚上8点安排：写论文三小时、改代码两小时、健身一小时",
                  expects: [
                    .init(kind: .hasBlock, title: "午饭"),
                    .init(kind: .hasBlock, title: "晚饭"),
                    .init(kind: .anchorFlag, title: "午饭", flag: true),
                    .init(kind: .anchorFlag, title: "晚饭", flag: true),
                    .init(kind: .noOverlaps),
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

        // ===== arrange 排序（0.28.1：规则固化 vs LLM 对照；断言=数组推荐顺序，不看时间）=====
        BenchCase(id: "S1", name: "尽早★最前", capability: .arrange, dimension: "执行力",
                  blocks: [
                    .init(title: "整理邮箱", startHM: "09:00", durationMinutes: 30),
                    .init(title: "写论文", startHM: "10:00", durationMinutes: 120, priority: "important"),
                    .init(title: "读书", startHM: "14:00", durationMinutes: 60),
                  ],
                  fromHM: "08:30",
                  expects: [
                    .init(kind: .blockCountExact, count: 3),
                    .init(kind: .arrayOrderBefore, title: "写论文", title2: "整理邮箱"),
                    .init(kind: .arrayOrderBefore, title: "写论文", title2: "读书"),
                    .init(kind: .fixedUnmoved),
                  ]),
        BenchCase(id: "S2", name: "DDL 升序其次", capability: .arrange, dimension: "执行力",
                  blocks: [
                    .init(title: "随时的杂务", startHM: "09:00", durationMinutes: 30),
                    .init(title: "交报销", startHM: "15:00", durationMinutes: 30),
                    .init(title: "改简历", startHM: "11:00", durationMinutes: 60),
                  ],
                  fromHM: "08:30",
                  expects: [
                    .init(kind: .blockCountExact, count: 3),
                    .init(kind: .hasBlock, title: "交报销"),
                    .init(kind: .hasBlock, title: "改简历"),
                  ]),
        BenchCase(id: "S3", name: "锚点不占推荐位", capability: .arrange, dimension: "执行力",
                  blocks: [
                    .init(title: "午饭", startHM: "12:30", durationMinutes: 30, isAnchor: true),
                    .init(title: "写代码", startHM: "09:00", durationMinutes: 120),
                    .init(title: "健身", startHM: "16:00", durationMinutes: 60, priority: "important"),
                  ],
                  fromHM: "08:30",
                  expects: [
                    .init(kind: .blockCountExact, count: 3),
                    .init(kind: .arrayOrderBefore, title: "健身", title2: "写代码"),
                    .init(kind: .arrayOrderBefore, title: "写代码", title2: "午饭"),
                  ]),
        // ===== polish 润色（0.28.2：云端 vs 端侧对照；合成样例——真日记绝不进试验台）=====
        // 自动断言只锁底线（事实保留/错字修正/不瞎扩写）；结构与文风由人工评审（输出全文在 🐞/Downloads 日志「润色台」）。
        // rev 1（2026-07-11 Jason 拍板）：撤「开森」必改断言——W 组全文评审实证模型是在**保护刻意的
        // 网络语气**（真错字「下无」10/10 全修）；日记产品保留用户声音是对的行为，不算失败。
        BenchCase(id: "W1", name: "错别字修正", capability: .polish, dimension: "服从性",
                  text: "今天下无去了图书馆，把论文的绪论写完了。晚上和室友吃了火锅，聊到很晚，有点开森。",
                  expects: [
                    .init(kind: .rawNotContains, title: "下无"),
                    .init(kind: .rawContains, title: "图书馆"),
                    .init(kind: .rawContains, title: "火锅"),
                    .init(kind: .rawLengthRatio, count: 200),
                  ], rev: 1),
        BenchCase(id: "W2", name: "乱格式规整", capability: .polish, dimension: "服从性",
                  text: "##今天\n-写代码 三小时…修了那个bug!!\n   - 健身（40min\n明天记得：买菜、、交电费",
                  expects: [
                    .init(kind: .rawContains, title: "写代码"),
                    .init(kind: .rawContains, title: "健身"),
                    .init(kind: .rawContains, title: "交电费"),
                    .init(kind: .rawLengthRatio, count: 250),
                  ]),
        BenchCase(id: "W3", name: "病句轻润色·意思不变", capability: .polish, dimension: "服从性",
                  text: "今天的话就是那个实验又失败了但是我觉得可能是试剂的问题吧应该，然后重新配了一次就好了，导师说下周组会我来讲。",
                  expects: [
                    .init(kind: .rawContains, title: "试剂"),
                    .init(kind: .rawContains, title: "组会"),
                    .init(kind: .rawLengthRatio, count: 180),
                  ]),
        BenchCase(id: "W4", name: "平直长文→结构化富文本", capability: .polish, dimension: "理解力",
                  text: "早上八点起床先去食堂吃了早饭然后去教室上了两节数学课下午回宿舍睡了个午觉起来之后去图书馆写数据库作业写到五点半和同学去吃了麻辣烫晚上七点去健身房练了背和二头回来洗澡之后看了一集纪录片十一点半睡觉总的来说今天过得挺充实的但是数学课有点没听懂明天要找时间补一下。",
                  expects: [
                    .init(kind: .rawContains, title: "图书馆"),
                    .init(kind: .rawContains, title: "健身"),
                    .init(kind: .rawContains, title: "数学"),
                    .init(kind: .rawLengthRatio, count: 160),
                  ]),

        BenchCase(id: "S4", name: "固定块时间绝不动", capability: .arrange, dimension: "服从性",
                  blocks: [
                    .init(title: "组会", startHM: "10:00", durationMinutes: 60, isFixed: true),
                    .init(title: "写周报", startHM: "13:00", durationMinutes: 60, priority: "important"),
                  ],
                  fromHM: "09:00",
                  expects: [
                    .init(kind: .fixedUnmoved),
                    .init(kind: .blockCountExact, count: 2),
                    .init(kind: .arrayOrderBefore, title: "写周报", title2: "组会"),
                  ]),
    ]

    private static let refineBase: [BenchBlockSpec] = [
        .init(title: "写作", startHM: "09:00", durationMinutes: 120),
        .init(title: "会议", startHM: "11:30", durationMinutes: 60, isFixed: true),
        .init(title: "阅读", startHM: "14:00", durationMinutes: 60),
    ]
}
