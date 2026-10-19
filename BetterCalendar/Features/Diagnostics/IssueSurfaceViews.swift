//
//  IssueSurfaceViews.swift
//  BetterCalendar
//
//  W16「安静但可见」的三个出口（判定全在 IssueTriage / DevLog，这里只负责画）：
//  - IssueBanner：你能处理的 / 已持续失败的 → 白话横幅 + 怎么办 + 「知道了」，点开看日志；
//  - IssueLogButton：🐞 日志入口，安静中的短暂问题只在这里显示一个小计数（恢复后自动消失）；
//  - InlineIssueText：面板 / 对话里的就地错误（lastError）走同一判定——短暂问题升级前不显示。
//

import SwiftUI

struct IssueBanner: View {
    var body: some View {
        if let issue = DevLog.shared.bannerIssue {
            let tint: Color = issue.level == .error && !issue.escalated ? .red : .orange
            HStack(alignment: .top, spacing: 6) {
                NavigationLink { DevLogView() } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: issue.escalated ? "clock.badge.exclamationmark" : "exclamationmark.triangle.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.text).font(.caption)
                            if let action = issue.action { Text("怎么办：" + action).font(.caption2) }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button("知道了") { DevLog.shared.acknowledge(issue.key) }
                    .font(.caption2).buttonStyle(.plain).underline()
            }
            .padding(8)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// 🐞 日志入口（工具栏）。有安静中的短暂问题时带一个小数字；没有就只是一个灰色小虫。
struct IssueLogButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        let n = DevLog.shared.quietIssueCount
        Button { isPresented = true } label: {
            Label(n > 0 ? "日志（\(n) 个小问题，会自己恢复）" : "日志", systemImage: n > 0 ? "ladybug.fill" : "ladybug")
        }
        .help(n > 0 ? "后台有 \(n) 个短暂问题（网络/iCloud 等），恢复后自动消失；点开看详情" : "开发日志")
        .accessibilityIdentifier("bc.devlog.open")
        .overlay(alignment: .topTrailing) {
            if n > 0 {
                Text("\(n)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 3).background(Capsule().fill(Color.secondary))
                    .offset(x: 6, y: -4).allowsHitTesting(false)
            }
        }
    }
}

/// 日志页的 sheet 包装（自带导航栈和关闭按钮，Mac / iPhone 通用）。
struct DevLogSheet: View {
    @Binding var isPresented: Bool
    var body: some View {
        NavigationStack {
            DevLogView()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { isPresented = false } } }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 620, minHeight: 420, idealHeight: 600)
        #endif
    }
}

/// 面板 / 对话里的就地错误：同一判定（短暂问题升级前不显示；日志里一条不少）。
struct InlineIssueText: View {
    let source: String
    let message: String?
    var font: Font = .caption

    var body: some View {
        if let message, DevLog.shared.shouldShowInline(source: source, message: message) {
            Text(IssueTriage.plainText(message)).font(font).foregroundStyle(.orange)
        }
    }
}
