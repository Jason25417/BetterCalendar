//
//  ChatSourcesView.swift
//  BetterCalendar
//
//  W40（Jason 2026-10-22）：智能体用到的网页来源——默认收成一个「来源」小按钮，点了才展开链接（不在正文里贴网址）。
//

import SwiftUI

struct ChatSourcesView: View {
    let sources: [ChatSource]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                Label("来源 \(sources.count)", systemImage: open ? "chevron.down" : "link").font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("bc.chat.sources")
            if open {
                ForEach(sources, id: \.self) { s in
                    if let url = URL(string: s.url) {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).font(.caption).lineLimit(2)
                                Text(url.host() ?? s.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }
}
