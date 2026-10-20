//
//  JournalAuthorship.swift
//  BetterCalendar
//
//  W32b（Jason 2026-10-20）：日记里「智能体写的」与「你写的」靠**固定的字体样式**区分（他更喜欢这个，不要标签）。
//  标记存在 JournalEntry.body 里（不改 CloudKit schema）：开发期正文是 Markdown，用 Markdown 的标准做法——HTML 注释
//    <!--bc:agent:1a2b3c4d-->智能体写的文字<!--/bc:agent-->
//  · Markdown 渲染器里不可见；编辑（纯文本）、导出（原样保留，换个 Markdown 工具也看不见、不丢）、同步都原样往返；
//  · 1a2b3c4d = 这段文字的指纹（SHA256 前 4 字节）。**你在这段里改了任何一个字，指纹就对不上——整段算你的文字**
//    （照常字体显示，标记变成无效、不再起作用）。所以「你改过的就是你的」不需要编辑器配合，也不会误标；
//  · 搜索、回收站标题、给智能体的摘要以外的地方一律先 plainText（去掉标记）；残缺的标记（只剩一半）也一并去掉；
//  · 上线换富文本（bodyFormat = richText）时，这个约定映射成一个文字属性即可。
//

import CryptoKit
import Foundation
import SwiftUI

nonisolated enum JournalAuthorship {
    struct Segment: Equatable { var text: String; var byAgent: Bool }

    static let closeTag = "<!--/bc:agent-->"
    private static let pair = try! NSRegularExpression(pattern: #"<!--bc:agent:([0-9a-f]{8})-->(.*?)<!--/bc:agent-->"#,
                                                       options: [.dotMatchesLineSeparators])
    /// 任何残缺 / 失效的标记片段（渲染与搜索时去掉）。
    private static let stray = try! NSRegularExpression(pattern: #"<!--/?bc:agent(:[0-9a-f]{0,8})?-->"#)

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// 把一段智能体写的文字包上标记。
    static func mark(_ text: String) -> String { "<!--bc:agent:\(fingerprint(text))-->" + text + closeTag }

    /// 在正文末尾加一段智能体写的文字（空正文直接是这一段；否则空一行再接）。
    static func appending(_ text: String, to body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? mark(text) : body.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "\n\n" + mark(text)
    }

    /// 文本按作者切段（标记去掉；指纹对不上的 = 你改过 = 你的）。
    static func segments(_ body: String) -> [Segment] {
        let ns = body as NSString
        var out: [Segment] = []
        var cursor = 0
        func plain(_ s: String) {
            let cleaned = stray.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
            if !cleaned.isEmpty { append(Segment(text: cleaned, byAgent: false)) }
        }
        func append(_ seg: Segment) {
            if let last = out.last, last.byAgent == seg.byAgent { out[out.count - 1].text += seg.text } else { out.append(seg) }
        }
        for m in pair.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            plain(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            let fp = ns.substring(with: m.range(at: 1)), text = ns.substring(with: m.range(at: 2))
            if fingerprint(text) == fp { if !text.isEmpty { append(Segment(text: text, byAgent: true)) } } else { plain(text) }
            cursor = m.range.location + m.range.length
        }
        plain(ns.substring(from: cursor))
        return out
    }

    /// 去掉标记后的纯文字（搜索 / 标题 / 统计用）。
    static func plainText(_ body: String) -> String { segments(body).map(\.text).joined() }

    /// 正文里有没有（有效的）智能体段落。
    static func hasAgentText(_ body: String) -> Bool { segments(body).contains(where: \.byAgent) }

    /// 智能体文字的固定样式：衬线 + 斜体（你的文字照常）。字号跟所在位置（正文 body、列表摘要 caption）。
    static func agentFont(_ style: Font.TextStyle = .body) -> Font { .system(style, design: .serif).italic() }
    static let agentFont = agentFont(.body)

    /// 不解析 Markdown、只按作者上样式（历史列表等原样显示正文的地方）。style = 所在位置的字阶（文字属性里的字体会盖过 .font 修饰）。
    static func styled(_ body: String, style: Font.TextStyle = .body) -> AttributedString {
        segments(body).reduce(into: AttributedString()) { out, seg in
            var a = AttributedString(seg.text)
            if seg.byAgent { a.font = agentFont(style) }
            out += a
        }
    }
}
