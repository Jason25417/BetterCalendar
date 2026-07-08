//
//  BenchVariants.swift
//  BetterCalendar
//
//  算法版本注册表（Jason 要求：保留过往版本、可实时切旧版对比）。
//  规则：**只追加、不删除**——冻结变体（frozen=true）是某版本行为的快照，日后线上算法演进，
//  这里的快照保持不变，对比才诚实。候选算法（如 reflow v2）在此孵化，毕业进线上后本体留档、加注毕业版本。
//

import Foundation

struct BenchVariant: Identifiable, Sendable {
    let id: String
    let capability: BenchCapability
    let name: String
    let detail: String
    let frozen: Bool   // true = 历史快照（prompt/管道拷贝定格，不随线上演进）
}

enum BenchVariantID {
    static let parseFM = "parse.fm"
    static let parseCloud = "parse.cloud"
    static let refineFM = "refine.fm"
    static let refineCloud = "refine.cloud"
    static let refineCloudGuard = "refine.cloud.guard"
    static let reflowNaiveV1 = "reflow.naive.v1"
    static let reflowLLMV1 = "reflow.llm.v1"
    static let reflowNaiveV2 = "reflow.naive.v2"
    static let reflowLLMV2 = "reflow.llm.v2"
}

enum BenchVariants {
    static let all: [BenchVariant] = [
        BenchVariant(id: BenchVariantID.parseFM, capability: .parse,
                     name: "端侧 FM 解析", detail: "FoundationModelsScheduleParser（现行，无云端回退）", frozen: false),
        BenchVariant(id: BenchVariantID.parseCloud, capability: .parse,
                     name: "云端解析", detail: "ClaudeScheduleParser（服务商/模型=当前设置，无本地回退）", frozen: false),
        BenchVariant(id: BenchVariantID.refineFM, capability: .refine,
                     name: "端侧 FM 微调", detail: "FoundationModelsPlanRefiner（裸输出，无防呆）", frozen: false),
        BenchVariant(id: BenchVariantID.refineCloud, capability: .refine,
                     name: "云端微调（裸）", detail: "ClaudePlanRefiner 裸输出——量模型本身的服从性", frozen: false),
        BenchVariant(id: BenchVariantID.refineCloudGuard, capability: .refine,
                     name: "云端微调+防呆", detail: "ClaudePlanRefiner + guardRefineFlags（= 现行线上组合）", frozen: false),
        BenchVariant(id: BenchVariantID.reflowNaiveV1, capability: .reflow,
                     name: "本地 V1（现行）", detail: "原顺序 + ReflowLayout；收工线不执法、铺到深夜", frozen: true),
        BenchVariant(id: BenchVariantID.reflowLLMV1, capability: .reflow,
                     name: "LLM V1（现行 @0.22.2）", detail: "LLM 只定序（无 deferred 通道）+ ReflowLayout", frozen: true),
        BenchVariant(id: BenchVariantID.reflowNaiveV2, capability: .reflow,
                     name: "本地 V2 候补（候选）", detail: "原顺序 + 收工线硬执法 → 放不下进候补", frozen: false),
        BenchVariant(id: BenchVariantID.reflowLLMV2, capability: .reflow,
                     name: "LLM V2 候补（候选）", detail: "LLM 定序 + deferred 通道 + 本地收工线执法（双层）", frozen: false),
    ]

    static func of(_ capability: BenchCapability) -> [BenchVariant] {
        all.filter { $0.capability == capability }
    }
}

// MARK: - 冻结/候选 prompt（reflow 变体归试验台所有，prompt 在此定格）

enum BenchPrompts {

    /// V1 = LLMPlanningEngine.reflowSystemPrompt 的快照拷贝（@0.22.2，2026-07-08 冻结）。
    /// 收工时间从用例注入（线上版读 WorkHoursSettings——试验台要确定性，不读用户设置）。
    static func reflowSystemV1(windDownText: String) -> String {
        PromptConstitution.with("""
        你是「自愈排程大脑」。用户需要从现在起重排今天剩余（**不回顾、不算账**）。原则：
        1) **固定块（会议等）时间绝不动**；
        2) 撞固定块时，优先把"力所能及、固定块开始前来得及"的弹性块排到前面，智能重排顺序避免冲突；
        3) **收工时间（软限制）= \(windDownText)**：尽量别把弹性块排到收工时间之后（略超 5–10 分钟正好能多做完一件大事则可以）；排不进收工前的，**宁可今天不排（留给明天/以后）也别硬塞到深夜**。用户明确排在收工后的晚间块保持不动、别提前。
        4) 措辞给掌控感（"接下来这样就能收尾"），不施压（红线见宪法）。
        只输出 JSON：{"flexibleOrder":[弹性块索引...],"note":"一句温和前向的话"}
        """)
    }

    /// V1 user 消息（同线上 @0.22.2）。
    static func reflowUserV1(nowText: String, listing: String) -> String {
        """
        现在 \(nowText)。需要从现在起重排今天剩余。时间块（索引: 标题 [固定/弹性] 原起止）：
        \(listing)
        固定块时间不动；弹性块要在固定块开始前尽量塞"力所能及、来得及"的事避冲突。
        给出**弹性块**的推荐执行顺序（只列弹性块索引）+ 一句温和前向的 note。
        只输出 JSON：{"flexibleOrder":[弹性块索引...],"note":"一句话"}
        """
    }

    static let reflowSchemaV1: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["flexibleOrder", "note"],
        "properties": [
            "flexibleOrder": ["type": "array", "items": ["type": "integer"]],
            "note": ["type": "string"],
        ],
    ]

    /// V2 候选：deferred 通道——模型第一次拥有「今天不排」的表达能力（SPEC §11 ② 管道扩容）。
    static func reflowSystemV2(windDownText: String, graceMinutes: Int) -> String {
        PromptConstitution.with("""
        你是「自愈排程大脑」。用户需要从现在起重排今天剩余（**不回顾、不算账**）。原则：
        1) **固定块（会议等）时间绝不动**；标了 [晚间] 的块是用户自己排在收工后的，保持原时间、不提前不挪动。
        2) **收工线（硬约束）= \(windDownText)**（宽限 \(graceMinutes) 分钟）：按你给的顺序从现在起依次铺开，整块放不进 收工线+宽限 的弹性块，放进 deferred（= 候补：今天不排时间、温和地留在清单里可随时手动开始，**不是失败不是删除**）。
        3) **[★] 要紧事绝不放 deferred**——超线也照排，它的去留由用户决定，不由你。
        4) 排序智能：短平快的事可以排在大块之前塞进空隙，让收工线内完成的件数更多；撞固定块的顺延规则由本地铺排处理，你只管顺序与取舍。
        5) [并行:组名] 的块会被本地绑定为同一时段，视作一个槽考虑。
        6) 措辞给掌控感（"接下来这样就能收尾"），不施压（红线见宪法）。
        只输出 JSON：{"flexibleOrder":[要排的弹性块索引，按执行顺序],"deferred":[进候补的弹性块索引],"note":"一句温和前向的话"}
        """)
    }

    static func reflowUserV2(nowText: String, listing: String) -> String {
        """
        现在 \(nowText)。需要从现在起重排今天剩余。时间块（索引: 标题 [固定/弹性][标记] 原起止）：
        \(listing)
        给出弹性块的执行顺序 flexibleOrder + 放不进收工线的候补 deferred（两者不重复、合起来覆盖全部弹性块）+ 一句 note。
        """
    }

    static let reflowSchemaV2: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["flexibleOrder", "deferred", "note"],
        "properties": [
            "flexibleOrder": ["type": "array", "items": ["type": "integer"]],
            "deferred": ["type": "array", "items": ["type": "integer"]],
            "note": ["type": "string"],
        ],
    ]
}
