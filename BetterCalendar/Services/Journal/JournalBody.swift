//
//  JournalBody.swift
//  BetterCalendar
//
//  正文格式接口（R2）：按 JournalEntry.bodyFormat 渲染正文。开发期 markdown；上线换 richText（见 SPEC §9）。
//  编辑仍是纯文本 TextEditor，渲染只用于「预览」。
//

import Foundation
import SwiftUI

enum JournalBodyFormat: String { case markdown, richText }

enum JournalBody {
    static func rendered(_ body: String, format: String) -> AttributedString {
        switch JournalBodyFormat(rawValue: format) ?? .markdown {
        case .markdown:
            // W32b：按作者切段，各段分别渲染 Markdown；智能体写的段落用固定字体（衬线 + 斜体），标记本身不显示。
            let opts = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return JournalAuthorship.segments(body).reduce(into: AttributedString()) { out, seg in
                var a = (try? AttributedString(markdown: seg.text, options: opts)) ?? AttributedString(seg.text)
                if seg.byAgent { JournalAuthorship.applyAgentStyle(&a, style: .body, cjkFontName: AgentCJKFont.shared.name) }   // W33：中文楷体 + 西文衬线斜体
                out += a
            }
        case .richText:
            return JournalAuthorship.styled(body)   // 占位：上线再做富文本渲染/编辑
        }
    }
}
