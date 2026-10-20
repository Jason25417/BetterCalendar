//
//  FeedbackView.swift
//  BetterCalendar
//
//  用户反馈（#31，2026-07-11 设计）：设置页入口 → 类型+描述+可选诊断 → 系统分享面板发出（零后端）。
//  隐私红线：诊断信息**显式勾选 + 全文可预览**；只含版本/系统与 DevLog 摘录，且剔除「行为」通道
//  （行为日志只存本地绝不上传的铁律延伸）；日记正文/日历内容没有任何进入路径。
//  内测期提示：TestFlight 自带截图反馈直达 App Store Connect，是更快的通道。
//

import SwiftUI

enum FeedbackComposer {
    /// 诊断信息（可预览的全文）：版本/系统 + 最近 DevLog ≤150 行（剔「行为」通道）。
    static func diagnostics() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let lines = DevLog.shared.entries
            .filter { $0.source != "行为" }
            .suffix(150)
            .map { "\(df.string(from: $0.time)) [\($0.level.rawValue)] \($0.source): \($0.message)" }
        return """
        BetterCalendar \(AppInfo.version) (\(build)) · \(platform) \(os)
        —— 最近日志（已剔除行为通道）——
        \(lines.joined(separator: "\n"))
        """
    }

    static func compose(type: String, text: String, attachDiagnostics: Bool) -> String {
        var out = """
        # BetterCalendar 反馈 · \(type)

        \(text.isEmpty ? "（未填写描述）" : text)
        """
        if attachDiagnostics {
            out += "\n\n—— 诊断信息（发送者选择附上）——\n" + diagnostics()
        }
        return out
    }
}

/// 反馈表单（设置页 sheet）。发送 = 系统分享面板（邮件/信息/存文件由用户自选）。
struct FeedbackView: View {
    @Environment(\.appTheme) private var theme   // 体检 #25：设置 scene 已注入主题（体检 #9）
    @Environment(\.dismiss) private var dismiss
    @State private var type = "问题"
    @State private var text = ""
    @State private var attach = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("发送反馈").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
            }
            Picker("类型", selection: $type) {
                Text("问题").tag("问题")
                Text("建议").tag("建议")
            }
            .pickerStyle(.segmented)
            // 体检 #25：正文输入区穿 surface 纸面卡（与日记编辑器同族，条文5大容器档12）
            TextEditor(text: $text)
                .persistedDraft($text, key: TextDraftKey.feedback)   // W29：重启后还在（系统分享面板不告诉我们发没发，由你点「清空」）
                .frame(minHeight: 120)
                .padding(6)
                .scrollContentBackground(.hidden)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary.opacity(0.4)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("说说遇到的问题或想法…").foregroundStyle(.tertiary).padding(10).allowsHitTesting(false)
                    }
                }
            Toggle("附上诊断信息（版本 / 系统 / 最近日志）", isOn: $attach)
            if attach {
                ScrollView {
                    Text(FeedbackComposer.diagnostics())
                        .font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))   // 体检 #4：圆角归三档
                Text("以上就是会附上的全部内容（已剔除行为通道；日记与日历内容不会进入反馈）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("内测期更快通道：TestFlight 里对 App 截图即可直达反馈。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !text.isEmpty {
                    Button("清空") { text = ""; TextDraftStore.shared.clear(TextDraftKey.feedback) }
                }
                ShareLink(item: FeedbackComposer.compose(type: type, text: text, attachDiagnostics: attach),
                          subject: Text("BetterCalendar 反馈 · \(type)")) {
                    Label("发送反馈…", systemImage: "paperplane")
                }
                .disabled(text.isEmpty)
            }
        }
        .padding()
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}
