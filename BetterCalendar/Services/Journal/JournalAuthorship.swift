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

import CoreText
import CryptoKit
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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

    /// 智能体文字的固定样式（W33，Jason 定）：中文用楷体、拉丁字母和数字用衬线斜体（中文没有斜体，只换衬线几乎看不出来）。
    /// 楷体不在时（iOS 默认不带、按需下载）先用衬线顶上，并在 DevLog 记一笔；下载好后自动换上。字号跟所在位置（正文 body、列表摘要 caption）。
    static func agentFont(_ style: Font.TextStyle = .body) -> Font { .system(style, design: .serif).italic() }
    static let agentFont = agentFont(.body)

    /// 给一段智能体文字上样式：按字符切成「中日韩」和「其他」两种连续段，各自上字体。纯函数（字体名由调用方给，便于测试）。
    static func applyAgentStyle(_ a: inout AttributedString, style: Font.TextStyle, cjkFontName: String?) {
        let latin = agentFont(style)
        let cjk: Font = cjkFontName.map { Font.custom($0, size: AgentCJKFont.baseSize(style), relativeTo: style) } ?? latin
        var i = a.startIndex
        while i < a.endIndex {
            let isCJK = AgentCJKFont.isCJK(a.characters[i])
            var j = a.characters.index(after: i)
            while j < a.endIndex, AgentCJKFont.isCJK(a.characters[j]) == isCJK { j = a.characters.index(after: j) }
            a[i..<j].font = isCJK ? cjk : latin
            i = j
        }
    }

    /// 不解析 Markdown、只按作者上样式（历史列表等原样显示正文的地方）。style = 所在位置的字阶（文字属性里的字体会盖过 .font 修饰）。
    @MainActor static func styled(_ body: String, style: Font.TextStyle = .body) -> AttributedString {
        segments(body).reduce(into: AttributedString()) { out, seg in
            var a = AttributedString(seg.text)
            if seg.byAgent { applyAgentStyle(&a, style: style, cjkFontName: AgentCJKFont.shared.name) }
            out += a
        }
    }
}

/// W33：智能体中文用的楷体。macOS 26 自带 Kaiti SC / STKaiti；iOS 26 不带（模拟器运行时核实：只有 PingFang，没有楷体 / 宋体），
/// 要用 CoreText 的系统可下载字体按需下载。没有楷体时 name = nil（调用方退回衬线斜体），并记一次 DevLog——失败可见。
@MainActor @Observable final class AgentCJKFont {
    static let shared = AgentCJKFont()
    /// 可用的楷体字体名（PostScript 名优先）；nil = 还没有。
    private(set) var name: String?
    nonisolated static let candidates = ["STKaitiSC-Regular", "STKaiti", "Kaiti SC"]
    @ObservationIgnored private var requested = false

    private init() { name = Self.installedName() }

    nonisolated static func installedName() -> String? {
        candidates.first { n in
            #if canImport(UIKit)
            UIFont(name: n, size: 12) != nil
            #else
            NSFont(name: n, size: 12) != nil
            #endif
        }
    }

    /// App 启动时调一次：没有楷体就向系统要（iOS 的可下载字体），要到之前退回衬线并记日志。
    func ensureAvailable() {
        guard name == nil, !requested else { return }
        requested = true
        if TestHost.isActive { return }   // 测试宿主不发起下载
        DevLog.shared.warn("日记", "本机没有楷体：智能体写的中文先用衬线显示，正在向系统下载楷体")
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: Self.candidates[0]] as CFDictionary)
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler([desc] as CFArray, nil) { state, progress in
            switch state {
            case .didFinish:
                Task { @MainActor in
                    let got = Self.installedName()
                    AgentCJKFont.shared.name = got
                    if got == nil { DevLog.shared.warn("日记", "楷体下载结束但仍不可用：智能体写的中文继续用衬线显示") }
                    else { DevLog.shared.info("日记", "楷体已就绪：智能体写的中文改用楷体") }
                }
            case .didFailWithError:
                let err = (progress as NSDictionary)[kCTFontDescriptorMatchingError] as? NSError
                Task { @MainActor in DevLog.shared.warn("日记", "楷体下载失败（\(err?.localizedDescription ?? "未知原因")）：智能体写的中文继续用衬线显示") }
            default: break
            }
            return true
        }
    }

    /// 中日韩表意字符与中文标点（这些用楷体；其余——字母、数字、空格、西文标点——用衬线斜体）。
    nonisolated static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            switch s.value {
            case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F: return true
            default: return false
            }
        }
    }

    /// 各字阶的基准字号（Font.custom relativeTo 会随动态字体缩放）。
    nonisolated static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        #if os(macOS)
        switch style { case .caption, .caption2: return 10; case .footnote: return 10; case .callout: return 12; case .headline, .body: return 13; default: return 13 }
        #else
        switch style { case .caption: return 12; case .caption2: return 11; case .footnote: return 13; case .callout: return 16; default: return 17 }
        #endif
    }
}
