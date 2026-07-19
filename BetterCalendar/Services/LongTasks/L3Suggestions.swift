//
//  L3Suggestions.swift
//  BetterCalendar
//
//  L3「主动建议」（唯一主动，见 SPEC §5.11）：排日程页顶部一行温和文案。
//  **固定措辞库**（Jason 可随时改这里的字）+ **规则触发**——用户看到的句子永远来自库、不自由生成。
//  红线：触发可看 DDL/节奏，但话语绝不审计用户过去（不提"久没碰/落后/欠"）；措辞朝前、可无视。
//  约束：休息日全静音、"别再提"永久静音该任务、每天条数≤强度档（温和1/更主动2/关闭0）。
//

import Foundation

enum L3Kind: String, Sendable { case deadline, invite, shelve }

struct L3Suggestion: Identifiable, Sendable {
    let id: UUID          // = 任务 id
    let text: String
    let kind: L3Kind
}

/// 固定措辞库。{t}=任务名、{d}=期限描述。**Jason 审改这里即可**，改数据不改逻辑。
enum L3Phrases {
    static func deadline(_ t: String, _ d: String) -> String { "「\(t)」\(d)要交，今天留一小段给它就很稳。" }
    static func invite(_ t: String) -> String { "要不要给「\(t)」留 20 分钟？开个头往往就顺了。" }
    /// 有阶段时的邀请（#40 批3）：说清下一步是什么——比笼统的任务名更容易起步（措辞照旧问句、不催）。
    static func inviteWithCheckpoint(_ t: String, _ cp: String) -> String {
        "「\(t)」的下一步是「\(cp)」——要不要留 20 分钟开个头？"
    }
    static func shelve(_ t: String) -> String { "「\(t)」放了挺久了——要不要先放下？随时能在历史里捞回来，不是放弃。" }
}

extension LongTaskStore {
    /// 计算当前 L3 建议（纯读、可测口径）：休息日/关闭→空；静音集排除；至多 intensity 条。
    /// 触发：DDL 早过>7天→先放下；DDL 0–3天内→提醒；无DDL但有节奏且今天没碰→温和邀请。
    func l3Suggestions(now: Date = .now, loose: Bool, intensity: Int, muted: Set<UUID>) -> [L3Suggestion] {
        guard !loose, intensity > 0 else { return [] }
        var out: [L3Suggestion] = []
        let cal = Calendar.current
        for t in active() where !muted.contains(t.id) {
            if let d = t.deadline {
                let days = cal.dateComponents([.day], from: now, to: d).day ?? 0
                if days < -7 {
                    out.append(L3Suggestion(id: t.id, text: L3Phrases.shelve(t.title), kind: .shelve))
                } else if days >= 0 && days <= 3 {
                    let dtext = days == 0 ? "今天" : "\(days) 天后"
                    out.append(L3Suggestion(id: t.id, text: L3Phrases.deadline(t.title, dtext), kind: .deadline))
                }
            } else if t.cadenceMinutesPerWeek != nil, investedMinutes(for: t, on: now) == 0 {
                let text = t.nextCheckpoint.map { L3Phrases.inviteWithCheckpoint(t.title, $0.title) }
                    ?? L3Phrases.invite(t.title)
                out.append(L3Suggestion(id: t.id, text: text, kind: .invite))
            }
            if out.count >= intensity { break }
        }
        return Array(out.prefix(intensity))
    }
}
