//
//  JournalBody.swift
//  BetterCalendar
//
//  正文格式接口（R2）：按 JournalEntry.bodyFormat 渲染正文。开发期 markdown；上线换 richText（见 SPEC §9）。
//  编辑仍是纯文本 TextEditor，渲染只用于「预览」。
//

import Foundation

enum JournalBodyFormat: String { case markdown, richText }

enum JournalBody {
    static func rendered(_ body: String, format: String) -> AttributedString {
        switch JournalBodyFormat(rawValue: format) ?? .markdown {
        case .markdown:
            let opts = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return (try? AttributedString(markdown: body, options: opts)) ?? AttributedString(body)
        case .richText:
            return AttributedString(body)   // 占位：上线再做富文本渲染/编辑
        }
    }
}
